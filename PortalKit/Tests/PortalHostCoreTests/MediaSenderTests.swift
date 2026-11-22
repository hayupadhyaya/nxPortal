#if os(macOS)
import CryptoKit
import XCTest
import PortalKit
@testable import PortalHostCore

/// The sender's pacing, with time as an argument -> .claude/host.md § sender
final class PacingQueuesTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    /// 100 Mbit/s: a 100-datagram frame is then well inside the 8 ms window.
    private let fastRate = 100_000_000.0 / 8

    private func frame(_ number: UInt32, _ n: Int, key: Bool = false, repair: Bool = false) -> [VideoFragment] {
        (0..<n).map { VideoFragment(frame: number, index: UInt16($0), count: UInt16(n), key: key, repair: repair, captureNs: UInt64(number),
                                    width: 64, height: 64, payload: Data(repeating: 7, count: Wire.maxVideoPayload)) }
    }

    /// What `drain` offered, with the time of the call.
    private struct Out { var at: UInt64; var d: Datagram }

    private func drain(_ q: inout PacingQueues, at t: UInt64, into log: inout [Out],
                       outcome: (Datagram) -> TransmitOutcome = { _ in .sent }) {
        var got: [Out] = []
        q.drain(nowNs: t) { d, _ in
            let o = outcome(d)
            if o != .wouldBlock { got.append(Out(at: t, d: d)) }
            return o
        }
        log += got
    }

    /// Every millisecond from `a` to `b` inclusive.
    private func ticks(_ a: UInt64, _ b: UInt64) -> [UInt64] { Array(stride(from: a / ms, through: b / ms, by: 1).map { $0 * ms }) }

    private func isVideo(_ o: Out, frame f: UInt32) -> Bool { if case let .video(v) = o.d { return v.frame == f }; return false }

    func testAHundredDatagramFrameLeavesInSlicesOverEightMilliseconds() {
        var q = PacingQueues(paceNs: 8 * ms)
        _ = q.enqueueFrame(frame(1, 100), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        for t in ticks(0, 12 * ms) { drain(&q, at: t, into: &log) }
        XCTAssertEqual(log.count, 100)
        let times = Set(log.map(\.at))
        XCTAssertGreaterThanOrEqual(times.count, 6, "slices: \(times.sorted().map { $0 / ms })")
        let span = Double(log.last!.at - log.first!.at) / 1e6
        XCTAssertTrue((7...9).contains(span), "spread over \(span) ms")
        XCTAssertEqual(log.compactMap { if case let .video(v) = $0.d { v.index } else { nil } }, (0..<100).map(UInt16.init), "in order")
        XCTAssertEqual(q.counts.framesSent, 1)
    }

    private var loadDatagram: Datagram { .load(HostLoad(cpuTotal: 1)) }

    func testALazyDatagramWaitsBehindEveryVideoAndResendDatagram() {
        var q = PacingQueues(paceNs: 8 * ms)
        _ = q.enqueueFrame(frame(1, 100), nowNs: 0, bytesPerSecond: fastRate)
        q.enqueueResend(frame(0, 1)[0], nowNs: 0)
        q.setLazy(loadDatagram)
        var log: [Out] = []
        for t in ticks(0, 12 * ms) { drain(&q, at: t, into: &log) }
        let lazyAt = log.firstIndex { if case .load = $0.d { true } else { false } }
        XCTAssertEqual(lazyAt, 101, "after the 100 video and the 1 resend datagrams, once")
        XCTAssertEqual(log.filter { if case .load = $0.d { true } else { false } }.count, 1)
        XCTAssertFalse(q.hasLazy)
    }

    func testANewerLazyDatagramReplacesTheOneWaiting() {
        var q = PacingQueues(paceNs: 8 * ms)
        q.setLazy(.load(HostLoad(cpuTotal: 1)))
        q.setLazy(.load(HostLoad(cpuTotal: 2)))
        var log: [Out] = []
        drain(&q, at: 0, into: &log)
        XCTAssertEqual(log.map(\.d), [.load(HostLoad(cpuTotal: 2))])
    }

    func testARefusedLazyDatagramIsKeptForTheNextSliceAndNeverSpins() {
        var q = PacingQueues(paceNs: 8 * ms)
        q.setLazy(loadDatagram)
        var log: [Out] = []
        drain(&q, at: 0, into: &log, outcome: { _ in .wouldBlock })
        XCTAssertTrue(log.isEmpty)
        XCTAssertTrue(q.hasLazy)
        XCTAssertEqual(q.nextWakeNs(nowNs: 0), ms, "a slice later, not at once")
        drain(&q, at: ms, into: &log)
        XCTAssertEqual(log.count, 1)
        XCTAssertNil(q.nextWakeNs(nowNs: ms))
    }

    func testAUrgentDatagramStillLeavesAheadOfALazyOne() {
        var q = PacingQueues(paceNs: 8 * ms)
        q.setLazy(loadDatagram)
        var log: [Out] = []
        q.sendUrgent(.ping(clientNs: 1), nowNs: 0, emit: { d, _ in log.append(Out(at: 0, d: d)); return .sent })
        drain(&q, at: 0, into: &log)
        XCTAssertEqual(log.map(\.d), [.ping(clientNs: 1), loadDatagram])
    }

    func testAnEightDatagramFrameLeavesAtOnce() {
        var q = PacingQueues(paceNs: 8 * ms)
        _ = q.enqueueFrame(frame(1, 8), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)
        XCTAssertEqual(log.count, 8)
        XCTAssertNil(q.nextWakeNs(nowNs: 0))
    }

    func testPaceZeroSendsEveryFrameAtOnce() {
        var q = PacingQueues(paceNs: 0)
        _ = q.enqueueFrame(frame(1, 150, key: true), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)
        XCTAssertEqual(log.count, 150)
    }

    /// Urgent datagrams do not wait for a slice or a drain: `sendUrgent` emits at once.
    func testAnUrgentDatagramLeavesAtOnceBetweenSlices() {
        var q = PacingQueues(paceNs: 8 * ms)
        _ = q.enqueueFrame(frame(1, 100), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)
        drain(&q, at: ms, into: &log)
        let before = log.count
        var sent: [Datagram] = []
        q.sendUrgent(.pong(clientNs: 1, hostNs: 2), nowNs: ms + ms / 2) { d, _ in sent.append(d); return .sent }
        XCTAssertEqual(sent, [.pong(clientNs: 1, hostNs: 2)], "emitted inside the call, between two slices")
        XCTAssertEqual(log.count, before)
        XCTAssertFalse(q.hasUrgent)
    }

    func testResendsLeaveBeforeNewVideoAtThirtyTwoASlice() {
        var q = PacingQueues(paceNs: 8 * ms)
        for f in frame(9, 100) { q.enqueueResend(f, nowNs: 0) }
        _ = q.enqueueFrame(frame(10, 100), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)
        let first = log.prefix(32).allSatisfy { isVideo($0, frame: 9) }
        XCTAssertTrue(first, "the slice starts with 32 resends")
        XCTAssertEqual(log.filter { isVideo($0, frame: 9) }.count, 32, "no more than 32 resends in a slice")
        XCTAssertTrue(log.dropFirst(32).allSatisfy { isVideo($0, frame: 10) })
        XCTAssertFalse(log.dropFirst(32).isEmpty, "the slice's new video follows")
        drain(&q, at: ms, into: &log)
        XCTAssertEqual(log.filter { isVideo($0, frame: 9) }.count, 64)
    }

    func testBacklogDropsWholeUnsentFramesOldestFirstNeverOneBegun() {
        var q = PacingQueues(paceNs: 8 * ms)
        // 12 Mbit/s: a 40-datagram frame (46 KB) has a 15.3 ms window.
        let rate = 12_000_000.0 / 8
        _ = q.enqueueFrame(frame(1, 40), nowNs: 0, bytesPerSecond: rate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)
        drain(&q, at: ms, into: &log)  // frame 1 is begun
        XCTAssertFalse(log.isEmpty)
        var dropped: [UInt32] = []
        for n in 2...12 { dropped += q.enqueueFrame(frame(UInt32(n), 40), nowNs: ms, bytesPerSecond: rate) }
        XCTAssertFalse(dropped.isEmpty, "more than 100 ms queued must drop")
        XCTAssertFalse(dropped.contains(1), "a frame already begun is never dropped")
        XCTAssertEqual(dropped, dropped.sorted(), "oldest unsent first")
        XCTAssertEqual(dropped.first, 2)
        XCTAssertEqual(q.counts.framesDropped, dropped.count)
        for t in ticks(2 * ms, 400 * ms) { drain(&q, at: t, into: &log) }
        let sent = Dictionary(grouping: log.compactMap { o -> UInt32? in if case let .video(v) = o.d { v.frame } else { nil } }, by: { $0 })
        for (f, v) in sent { XCTAssertEqual(v.count, 40, "frame \(f) left whole or not at all") }
        XCTAssertTrue(Set(sent.keys).isDisjoint(with: dropped))
        XCTAssertEqual(q.counts.framesSent, sent.count)
    }

    /// A refresh's key frame must not wait behind frames the client discards: they drop, the one begun stays.
    func testAKeyFrameDropsTheUnbegunFramesBeforeIt() {
        var q = PacingQueues(paceNs: 8 * ms)
        let rate = 20_000_000.0 / 8
        _ = q.enqueueFrame(frame(1, 37), nowNs: 0, bytesPerSecond: rate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)  // frame 1 begun
        XCTAssertEqual(q.enqueueFrame(frame(2, 37), nowNs: ms, bytesPerSecond: rate), [])
        XCTAssertEqual(q.enqueueFrame(frame(3, 37), nowNs: ms, bytesPerSecond: rate), [])
        XCTAssertEqual(q.enqueueFrame(frame(4, 146, key: true), nowNs: ms, bytesPerSecond: rate), [2, 3])
        XCTAssertEqual(q.counts.framesDropped, 2)
        for t in ticks(ms, 200 * ms) { drain(&q, at: t, into: &log) }
        let order = log.compactMap { o -> UInt32? in if case let .video(v) = o.d, v.index == 0 { v.frame } else { nil } }
        XCTAssertEqual(order, [1, 4], "frame 1 (begun) finishes, then the key frame; 2 and 3 never leave")
        XCTAssertEqual(log.filter { isVideo($0, frame: 1) }.count, 37)
    }

    /// An urgent datagram the socket refuses is sealed once, kept, and retried one slice later: no spin.
    func testARefusedUrgentDatagramIsSealedOnceAndRetriedAtTheNextSlice() {
        var q = PacingQueues(paceNs: 8 * ms)
        var seals = 0, attempts = 0
        var open = false
        var wire: [Datagram] = []
        let emit: (Datagram, inout Data?) -> TransmitOutcome = { d, cache in
            if cache == nil { seals += 1; cache = Data([1]) }
            attempts += 1
            if !open { return .wouldBlock }
            wire.append(d); return .sent
        }
        q.sendUrgent(.pong(clientNs: 5, hostNs: 6), nowNs: 0, emit: emit)
        XCTAssertTrue(q.hasUrgent, "refused: it waits")
        XCTAssertEqual(q.nextWakeNs(nowNs: 0), ms, "retried one slice later, never at once")
        // Hammering drain inside that slice does nothing.
        for t in stride(from: UInt64(0), to: ms, by: 100_000) { q.drain(nowNs: t, emit: emit) }
        XCTAssertEqual(attempts, 1)
        q.drain(nowNs: ms, emit: emit)  // refused again
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(q.nextWakeNs(nowNs: ms), 2 * ms)
        open = true
        q.drain(nowNs: 2 * ms, emit: emit)
        XCTAssertEqual(wire.first, .pong(clientNs: 5, hostNs: 6), "nothing was dropped, nothing overtook it")
        XCTAssertEqual(seals, 1, "sealed once, however often the socket refused it")
        XCTAssertFalse(q.hasUrgent)
    }

    /// Urgent datagrams that arrive while one waits queue behind it (order kept).
    func testUrgentDatagramsKeepTheirOrderBehindARefusedOne() {
        var q = PacingQueues(paceNs: 8 * ms)
        var open = false
        var wire: [UInt64] = []
        let emit: (Datagram, inout Data?) -> TransmitOutcome = { d, _ in
            guard open else { return .wouldBlock }
            if case let .pong(c, _) = d { wire.append(c) }
            return .sent
        }
        for i in 1...3 { q.sendUrgent(.pong(clientNs: UInt64(i), hostNs: 0), nowNs: 0, emit: emit) }
        open = true
        q.drain(nowNs: ms, emit: emit)
        XCTAssertEqual(wire, [1, 2, 3])
    }

    /// Lateness: a slice served 2.4 ms after it was due is recorded as 2400 us, with the percentile and worst.
    func testSliceLatenessIsRecorded() {
        var q = PacingQueues(paceNs: 8 * ms)
        _ = q.enqueueFrame(frame(1, 90), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)             // on time
        drain(&q, at: ms + 200_000, into: &log)  // 200 us late
        drain(&q, at: 4 * ms + 400_000, into: &log)  // due at 2 ms, 2.4 ms late
        let l = q.lateness
        XCTAssertEqual(l.slices, 3)
        XCTAssertEqual(l.maxUs, 2400)
        XCTAssertGreaterThanOrEqual(l.p95Us, 2400)
        XCTAssertEqual(q.takeWindowMaxUs(), 2400)
        XCTAssertEqual(q.takeWindowMaxUs(), 0, "the window starts again")
        XCTAssertEqual(q.lateness.maxUs, 2400)
    }

    /// Frames of 8 datagrams or fewer count towards the backlog: a blocked socket cannot grow the queue without bound.
    func testSmallFramesBehindABlockedSocketAreBoundedAndCounted() {
        var q = PacingQueues(paceNs: 8 * ms)
        _ = q.enqueueFrame(frame(1, 8), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log, outcome: { _ in .wouldBlock })  // the head cannot leave
        var dropped: [UInt32] = []
        for n in 2...300 { dropped += q.enqueueFrame(frame(UInt32(n), 4), nowNs: 0, bytesPerSecond: fastRate) }
        XCTAssertGreaterThan(dropped.count, 150, "\(dropped.count) dropped")
        XCTAssertEqual(q.counts.framesDropped, dropped.count)
        q.discardPaced()
        XCTAssertGreaterThan(q.counts.framesDropped, dropped.count, "frames that vanish with the queue are counted too")
    }

    func testAVideoDatagramThePathRefusesBlocksTheRestOfTheSliceOnly() {
        var q = PacingQueues(paceNs: 0)
        _ = q.enqueueFrame(frame(1, 10), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        var refused = false
        drain(&q, at: 0, into: &log, outcome: { d in
            if case let .video(v) = d, v.index == 4, !refused { refused = true; return .wouldBlock }
            return .sent
        })
        XCTAssertEqual(log.count, 4)
        drain(&q, at: ms, into: &log)
        XCTAssertEqual(log.compactMap { if case let .video(v) = $0.d { v.index } else { nil } }, (0..<10).map(UInt16.init))
    }

    /// A late wake-up sends the slices that are due; the schedule is not shifted.
    func testALateWakeCatchesUpWithoutShiftingTheSchedule() {
        var q = PacingQueues(paceNs: 8 * ms)
        _ = q.enqueueFrame(frame(1, 90), nowNs: 0, bytesPerSecond: fastRate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)
        XCTAssertEqual(log.count, 10)
        drain(&q, at: 4 * ms + ms / 3, into: &log)  // woke 3 slices late
        XCTAssertEqual(log.count, 50, "slices 1 to 4 are due: 5 of 9 slices of 90")
        for t in ticks(5 * ms, 8 * ms) { drain(&q, at: t, into: &log) }
        XCTAssertEqual(log.count, 90, "still done at slice 8")
        XCTAssertEqual(log.last?.at, 8 * ms)
    }

    func testNoFrameLeavesFasterThanThreeTimesTheVideoRate() {
        var q = PacingQueues(paceNs: 8 * ms)
        let rate = 20_000_000.0 / 8
        _ = q.enqueueFrame(frame(1, 146, key: true), nowNs: 0, bytesPerSecond: rate)
        var log: [Out] = []
        for t in ticks(0, 100 * ms) { drain(&q, at: t, into: &log) }
        XCTAssertEqual(log.count, 146)
        let span = Double(log.last!.at) / 1e6
        // 146 x 1147 B at 3 x 2.5 MB/s = 22 ms; not capped at a frame period
        XCTAssertTrue((20...25).contains(span), "a key frame at 20 Mbit/s left over \(span) ms")
        var q2 = PacingQueues(paceNs: 8 * ms)
        _ = q2.enqueueFrame(frame(2, 37), nowNs: 0, bytesPerSecond: rate)  // an ordinary frame: paceMs
        var log2: [Out] = []
        for t in ticks(0, 30 * ms) { drain(&q2, at: t, into: &log2) }
        XCTAssertTrue((7...9).contains(Double(log2.last!.at) / 1e6))
        // A frame four times as big, at a quarter of the rate it was told: 4 x 22 = 90 ms, past a frame period.
        var q3 = PacingQueues(paceNs: 8 * ms)
        _ = q3.enqueueFrame(frame(3, 584, key: true), nowNs: 0, bytesPerSecond: rate)
        var log3: [Out] = []
        for t in ticks(0, 200 * ms) { drain(&q3, at: t, into: &log3) }
        XCTAssertTrue((85...95).contains(Double(log3.last!.at) / 1e6), "\(Double(log3.last!.at) / 1e6)")
    }

    /// A key frame 20 times the average takes ~110 ms to leave: the frames behind it are not dropped for that, the key
    /// frame never is, and the next frame begins when it ends.
    func testALongKeyFrameDoesNotMakeTheFramesBehindItDrop() {
        var q = PacingQueues(paceNs: 8 * ms)
        let rate = 20_000_000.0 / 8
        _ = q.enqueueFrame(frame(1, 740, key: true), nowNs: 0, bytesPerSecond: rate)  // 20 x 37 datagrams
        var dropped: [UInt32] = []
        for n in 2...8 { dropped += q.enqueueFrame(frame(UInt32(n), 37), nowNs: UInt64(n) * 16 * ms, bytesPerSecond: rate) }
        XCTAssertEqual(dropped, [], "frames behind a long key frame dropped")
        var log: [Out] = []
        for t in ticks(0, 400 * ms) { drain(&q, at: t, into: &log) }
        let firsts = log.compactMap { o -> (UInt32, UInt64)? in if case let .video(v) = o.d, v.index == 0 { (v.frame, o.at) } else { nil } }
        XCTAssertEqual(firsts.map(\.0), [1, 2, 3, 4, 5, 6, 7, 8])
        let keyEnd = log.filter { isVideo($0, frame: 1) }.last!.at
        XCTAssertTrue((100 * ms...120 * ms).contains(keyEnd), "the key frame left over \(Double(keyEnd) / 1e6) ms")
        XCTAssertGreaterThan(firsts[1].1, keyEnd, "frame 2 begins when the key frame ends")
        XCTAssertEqual(q.counts.framesDropped, 0)
    }

    /// A key frame is never dropped for backlog, however much waits ahead of it.
    func testABacklogNeverDropsAKeyFrame() {
        var q = PacingQueues(paceNs: 8 * ms)
        let rate = 1_000_000.0 / 8
        _ = q.enqueueFrame(frame(1, 40), nowNs: 0, bytesPerSecond: rate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)  // frame 1 is leaving
        var dropped: [UInt32] = []
        dropped += q.enqueueFrame(frame(2, 40, key: true), nowNs: 0, bytesPerSecond: rate)  // the oldest unbegun
        for n in 3...8 { dropped += q.enqueueFrame(frame(UInt32(n), 40), nowNs: 0, bytesPerSecond: rate) }
        XCTAssertFalse(dropped.isEmpty, "the backlog should drop something")
        XCTAssertFalse(dropped.contains(2), "a key frame was dropped for backlog: \(dropped)")
        for t in ticks(ms, 5000 * ms) { drain(&q, at: t, into: &log) }
        XCTAssertTrue(log.contains { isVideo($0, frame: 2) })
    }

    /// A repair frame is a restart point too: never dropped for backlog, however much waits ahead of it.
    func testABacklogNeverDropsARepairFrame() {
        var q = PacingQueues(paceNs: 8 * ms)
        let rate = 1_000_000.0 / 8
        _ = q.enqueueFrame(frame(1, 40), nowNs: 0, bytesPerSecond: rate)
        var log: [Out] = []
        drain(&q, at: 0, into: &log)  // frame 1 is leaving
        var dropped: [UInt32] = []
        dropped += q.enqueueFrame(frame(2, 40, repair: true), nowNs: 0, bytesPerSecond: rate)  // the oldest unbegun
        for n in 3...8 { dropped += q.enqueueFrame(frame(UInt32(n), 40), nowNs: 0, bytesPerSecond: rate) }
        XCTAssertFalse(dropped.isEmpty, "the backlog should drop something")
        XCTAssertFalse(dropped.contains(2), "a repair frame was dropped for backlog: \(dropped)")
        for t in ticks(ms, 5000 * ms) { drain(&q, at: t, into: &log) }
        XCTAssertTrue(log.contains { isVideo($0, frame: 2) })
    }

    /// The client unreachable for 9 s with a socket that refuses everything (the interface queue is full): 60 frames and
    /// 200 sound datagrams a second go in, and what waits stays bounded (about 100 ms of video, about a second of sound);
    /// when the socket takes datagrams again the backlog is gone within 250 ms, and a key frame then leaves first of all.
    func testNineSecondsOfARefusingSocketDoNotQueueNineSecondsOfVideoOrSound() {
        var q = PacingQueues(paceNs: 4 * ms)
        let rate = 20_000_000.0 / 8
        var log: [Out] = []
        let refuse: (Datagram) -> TransmitOutcome = { _ in .wouldBlock }
        var dropped = 0, worstFrames = 0, worstUrgent = 0
        for i in 0..<540 {  // 9 s of 60 fps; every ms is a drain, a sound datagram every 5 ms
            let t0 = UInt64(i) * 16_667_000
            dropped += q.enqueueFrame(frame(UInt32(i), 37), nowNs: t0, bytesPerSecond: rate).count
            for k in 0..<17 {
                let t = t0 + UInt64(k) * ms
                if k % 5 == 0 { q.sendUrgent(.audio(seq: UInt32(i * 4 + k), captureNs: 0, pcm: Data(count: 960)), nowNs: t) { _, _ in .wouldBlock } }
                drain(&q, at: t, into: &log, outcome: refuse)
            }
            worstFrames = max(worstFrames, q.framesQueued)
            worstUrgent = max(worstUrgent, q.urgentQueued)
        }
        XCTAssertEqual(log.count, 0)
        XCTAssertLessThanOrEqual(worstFrames, 30, "\(worstFrames) frames waited")
        XCTAssertGreaterThan(dropped, 480, "\(dropped) frames dropped of 540")
        XCTAssertLessThanOrEqual(worstUrgent, 256, "\(worstUrgent) urgent datagrams waited")
        // The socket takes datagrams again.
        let back = UInt64(540) * 16_667_000 + 100 * ms
        for t in ticks(back, back + 250 * ms) { drain(&q, at: t, into: &log) }
        XCTAssertEqual(q.framesQueued, 0, "the backlog outlived 250 ms")
        XCTAssertEqual(q.urgentQueued, 0)
        let newest = log.compactMap { o -> UInt32? in if case let .video(v) = o.d { v.frame } else { nil } }.max()
        XCTAssertEqual(newest, 539, "the newest picture did not leave")
    }

    func testNothingQueuedMeansNoWake() {
        var q = PacingQueues(paceNs: 8 * ms)
        XCTAssertNil(q.nextWakeNs(nowNs: 0))
        _ = q.enqueueFrame(frame(1, 50), nowNs: 0, bytesPerSecond: fastRate)
        XCTAssertEqual(q.nextWakeNs(nowNs: 0), 0)
        var log: [Out] = []
        for t in ticks(0, 12 * ms) { drain(&q, at: t, into: &log) }
        XCTAssertNil(q.nextWakeNs(nowNs: 13 * ms))
    }
}

/// Records what reaches the socket.
private final class RecordingSocket: MediaTransmitting, @unchecked Sendable {  // lock-guarded
    private let lock = NSLock()
    private var list: [(ns: UInt64, bytes: Data)] = []
    private var refusing = false
    /// While set the socket answers `.wouldBlock` to everything.
    func refuse(_ on: Bool) { lock.lock(); refusing = on; lock.unlock() }
    func transmit(_ sealed: Data, to address: UDPAddress) -> TransmitOutcome {
        lock.lock(); defer { lock.unlock() }
        if refusing { return .wouldBlock }
        list.append((clock_gettime_nsec_np(CLOCK_UPTIME_RAW), sealed))
        return .sent
    }
    var sent: [(ns: UInt64, bytes: Data)] { lock.lock(); defer { lock.unlock() }; return list }
}

/// The thread and timer around the queues, on the real clock.
final class MediaSenderTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private let address = UDPAddress(bytes: Data([1, 2, 3]))

    private func fragments(_ number: UInt32, _ n: Int) -> [VideoFragment] {
        (0..<n).map { VideoFragment(frame: number, index: UInt16($0), count: UInt16(n), key: false, captureNs: 0,
                                    width: 64, height: 64, payload: Data(repeating: 1, count: 100)) }
    }

    private func wait(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return cond()
    }

    func testAFrameIsPacedAndSealedInTheOrderItLeaves() async throws {
        let socket = RecordingSocket()
        let sender = MediaSender(socket: socket, paceMs: 8)
        defer { sender.stop() }
        sender.attach(sealer: DatagramSealer(key: key, sessionID: 9), address: address)
        sender.setStream(bitsPerSecond: 100_000_000)
        // Resends, a frame and urgent datagrams overtaking each other: sealed on the way out, never in a different order.
        for f in fragments(4, 40) { sender.enqueue(.video(f), priority: .resend) }
        sender.enqueueFrame(fragments(5, 100))
        for i in 0..<30 { sender.enqueue(.pong(clientNs: UInt64(i), hostNs: 0), priority: .urgent) }
        let done = await wait { socket.sent.count >= 170 }
        XCTAssertTrue(done, "\(socket.sent.count) of 170 left")
        var opener = DatagramOpener(key: key, sessionID: 9)
        var counters: [UInt64] = []
        for s in socket.sent {
            XCTAssertNoThrow(try opener.open(s.bytes), "a datagram left out of counter order")
            counters.append(s.bytes.dropFirst(8).prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) })
        }
        XCTAssertEqual(counters, counters.sorted())
        XCTAssertEqual(counters, (0..<UInt64(counters.count)).map { $0 })
        let video = socket.sent.filter { $0.bytes.first == 0x20 }
        let span = Double(video.last!.ns - video.first!.ns) / 1e6
        XCTAssertTrue((4...30).contains(span), "100 datagrams left over \(span) ms")
        XCTAssertEqual(sender.counts.framesSent, 1)
        XCTAssertEqual(sender.counts.resent, 40)
    }

    /// An urgent datagram is on the wire before `enqueue` returns (no thread hop), and the sender then idles.
    func testAnUrgentDatagramIsOnTheWireBeforeEnqueueReturns() async throws {
        let socket = RecordingSocket()
        let sender = MediaSender(socket: socket, paceMs: 8)
        defer { sender.stop() }
        sender.attach(sealer: DatagramSealer(key: key, sessionID: 9), address: address)
        sender.enqueue(.pong(clientNs: 1, hostNs: 2), priority: .urgent)
        XCTAssertEqual(socket.sent.count, 1, "not on the wire when enqueue returned")
        sender.enqueue(.hostStats(HostStats(framesFromGame: 1, framesSent: 1, framesDropped: 0, resent: 0, rateBps: 1)), priority: .urgent)
        XCTAssertEqual(socket.sent.count, 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(socket.sent.count, 2)
    }

    /// Frames leave a slice at a time on the real thread; its lateness is measured.
    func testTheThreadPacesAFrameAndMeasuresItsLateness() async throws {
        let socket = RecordingSocket()
        let sender = MediaSender(socket: socket, paceMs: 8)
        defer { sender.stop() }
        sender.attach(sealer: DatagramSealer(key: key, sessionID: 9), address: address)
        sender.setStream(bitsPerSecond: 100_000_000)
        sender.enqueueFrame(fragments(1, 100))
        let done = await wait { socket.sent.count == 100 }
        XCTAssertTrue(done)
        let l = sender.lateness
        XCTAssertGreaterThanOrEqual(l.slices, 6)
        // Robust on a busy Mac: one preempted slice may be late by a scheduler quantum or more, so the check is that
        // most slices were on time (half within 5 ms) and that none was stuck (under 250 ms), not that the worst was small.
        let onTime = l.histogram[0..<(5_000 / PacingQueues.Lateness.bucketUs)].reduce(0, +)
        XCTAssertGreaterThanOrEqual(onTime * 2, l.slices, "only \(onTime) of \(l.slices) slices left within 5 ms")
        XCTAssertLessThan(l.maxUs, 250_000, "a slice left \(l.maxUs) us late")
    }

    /// A sender nobody stops (its owner was dropped) lets its thread go: the thread holds the core, not the sender.
    func testADroppedSenderEndsItsThread() async throws {
        weak var weakSocket: RecordingSocket?
        do {
            let socket = RecordingSocket()
            weakSocket = socket
            let sender = MediaSender(socket: socket, paceMs: 8)
            sender.attach(sealer: DatagramSealer(key: key, sessionID: 9), address: address)
            sender.enqueue(.pong(clientNs: 1, hostNs: 2), priority: .urgent)
            XCTAssertEqual(socket.sent.count, 1)
        }
        let released = await wait(3) { weakSocket == nil }
        XCTAssertTrue(released, "the sender's thread kept it alive")
    }

    /// Nothing leaves before attach or after detach: the socket refuses everything until after `detach`, so no slice
    /// can slip out in between whatever the thread does.
    func testNothingLeavesBeforeAttachOrAfterDetach() async throws {
        let socket = RecordingSocket()
        socket.refuse(true)
        let sender = MediaSender(socket: socket, paceMs: 8)
        defer { sender.stop() }
        sender.enqueue(.pong(clientNs: 1, hostNs: 2), priority: .urgent)
        sender.attach(sealer: DatagramSealer(key: key, sessionID: 9), address: address)
        sender.enqueueFrame(fragments(1, 100))
        sender.enqueue(.pong(clientNs: 3, hostNs: 4), priority: .urgent)
        sender.detach()
        sender.enqueue(.pong(clientNs: 1, hostNs: 2), priority: .urgent)
        socket.refuse(false)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(socket.sent.isEmpty, "\(socket.sent.count) left")
    }

    func testAFrameDroppedForBacklogIsReportedToTheCaller() {
        let socket = RecordingSocket()
        let sender = MediaSender(socket: socket, paceMs: 8)
        defer { sender.stop() }
        sender.attach(sealer: DatagramSealer(key: key, sessionID: 9), address: address)
        sender.setStream(bitsPerSecond: 1_000_000)  // 100 datagrams at 1 Mbit/s: a window of 300 ms each
        var dropped: [UInt32] = []
        for n in 0..<30 { dropped += sender.enqueueFrame(fragments(UInt32(n), 100)) }
        XCTAssertFalse(dropped.isEmpty)
        XCTAssertEqual(sender.counts.framesDropped, dropped.count)
    }
}
#endif
