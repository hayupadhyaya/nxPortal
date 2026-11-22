import XCTest
@testable import PortalKit

/// The assembler's window, nacks, give-up and key-frame rules, on synthetic fragments and times -> .claude/portalkit.md § video
final class FrameAssemblerTests: XCTestCase {
    private static let ms: UInt64 = 1_000_000
    private func t(_ x: Double) -> UInt64 { UInt64(x * 1e6) }

    private func bytes(_ n: Int, seed: UInt32) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// `n` fragments (the last one shorter).
    private func frags(_ frame: UInt32, key: Bool, _ n: Int = 5) -> [VideoFragment] {
        FrameSplitter.split(frame: frame, key: key, captureNs: 99, width: 1280, height: 720,
                            data: bytes(n * Wire.maxVideoPayload - 100, seed: frame))
    }

    private func data(_ frame: UInt32, _ n: Int = 5) -> Data { bytes(n * Wire.maxVideoPayload - 100, seed: frame) }

    private func push(_ a: inout FrameAssembler, _ fs: [VideoFragment], at now: UInt64) -> [AssemblerEvent] {
        fs.flatMap { a.push($0, nowNs: now) }
    }

    private func out(_ e: [AssemblerEvent]) -> [UInt32] { e.compactMap { if case let .frame(f) = $0 { f.frame } else { nil } } }
    private func nacks(_ e: [AssemblerEvent]) -> [Nack] {
        e.compactMap { if case let .nack(f, i) = $0 { Nack(frame: f, indices: i) } else { nil } }
    }
    private func refreshes(_ e: [AssemblerEvent]) -> Int { e.filter { if case .refresh = $0 { true } else { false } }.count }

    private struct Nack: Equatable { var frame: UInt32; var indices: [UInt16] }

    /// Key frame 1 out at t = 0.
    private func started() -> FrameAssembler {
        var a = FrameAssembler()
        XCTAssertEqual(out(push(&a, frags(1, key: true), at: 0)), [1])
        return a
    }

    // MARK: clean

    func testCleanStreamUnchanged() {
        var a = FrameAssembler()
        var all: [AssemblerEvent] = []
        for n in UInt32(1)...20 {
            let now = t(Double(n) * 16.7)
            all += push(&a, frags(n, key: n == 1), at: now)
            all += a.tick(nowNs: now + t(5), rttNs: 2 * Self.ms)
        }
        XCTAssertEqual(out(all), Array(1...20))
        XCTAssertEqual(all.count, 20, "only frames: \(all.filter { if case .frame = $0 { false } else { true } })")
        XCTAssertEqual(a.counts, AssemblerCounts())
        guard case let .frame(first) = all[0] else { return XCTFail() }
        XCTAssertEqual(first.data, data(1))
        XCTAssertTrue(first.key)
        XCTAssertEqual(first.captureNs, 99)
        XCTAssertEqual(first.width, 1280)
        XCTAssertEqual(first.height, 720)
        XCTAssertNil(a.nextTickNs(rttNs: 2 * Self.ms), "nothing missing: no timer")
    }

    // MARK: one loss

    func testALostFragmentIsAskedForAfterASettleAndTheFrameComesOutWhenItArrives() {
        var a = started()
        let f2 = frags(2, key: false)
        var e = push(&a, [f2[0], f2[1], f2[3]], at: t(20))
        XCTAssertEqual(e, [], "a hole is not asked for on sight (it may only be reordered)")
        XCTAssertEqual(a.nextTickNs(rttNs: 2 * Self.ms), t(21))
        XCTAssertEqual(a.tick(nowNs: t(20.9), rttNs: 2 * Self.ms), [])
        e = a.tick(nowNs: t(21), rttNs: 2 * Self.ms)
        XCTAssertEqual(nacks(e), [Nack(frame: 2, indices: [2])])
        XCTAssertEqual(push(&a, [f2[4]], at: t(21.5)), [])
        e = push(&a, [f2[2]], at: t(22))
        XCTAssertEqual(out(e), [2])
        guard case let .frame(f) = e.first else { return XCTFail() }
        XCTAssertEqual(f.data, data(2))
        XCTAssertEqual(a.counts, AssemblerCounts(nacksSent: 1, fragmentsAsked: 1, fragmentsRecovered: 1, framesRepaired: 1))
        XCTAssertNil(a.nextTickNs(rttNs: 2 * Self.ms))
    }

    func testALostTailIsAskedForAtOnceWhenTheNextFrameStarts() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: false)
        XCTAssertEqual(push(&a, Array(f2.prefix(3)), at: t(20)), [])
        let e = push(&a, [f3[0]], at: t(36))
        XCTAssertEqual(nacks(e), [Nack(frame: 2, indices: [3, 4])])
        XCTAssertEqual(out(push(&a, [f2[3], f2[4]], at: t(37))), [2])
        XCTAssertEqual(out(push(&a, Array(f3.dropFirst()), at: t(38))), [3])
    }

    func testAWholeLostFrameIsAskedForWhole() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: false)
        XCTAssertEqual(out(push(&a, f2, at: t(17))), [2])
        let e = push(&a, frags(4, key: false), at: t(50))
        XCTAssertEqual(nacks(e), [Nack(frame: 3, indices: [])])
        XCTAssertEqual(out(e), [])
        XCTAssertEqual(out(push(&a, f3, at: t(52))), [3, 4])
        XCTAssertEqual(a.counts.framesRepaired, 1)
        XCTAssertEqual(a.counts.fragmentsRecovered, 5, "every fragment of a frame asked for whole was asked for")
        XCTAssertEqual(a.counts.fragmentsAsked, 5)
    }

    func testANackHoldsAtMost64Indices() {
        var a = started()
        let f2 = frags(2, key: false, 200)
        XCTAssertEqual(push(&a, [f2[0], f2[199]], at: t(20)), [])
        let n = nacks(a.tick(nowNs: t(21), rttNs: 2 * Self.ms))
        XCTAssertEqual(n.map(\.indices.count), [64, 64, 64, 6])
        XCTAssertEqual(Set(n.flatMap(\.indices)), Set((1...198).map(UInt16.init)))
        XCTAssertEqual(a.counts.nacksSent, 4)
        XCTAssertEqual(a.counts.fragmentsAsked, 198)
    }

    // MARK: Review Focus 1

    func testARunAcrossTwoFramesIsAskedForAndBothComeOutInOrder() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: false)
        // Lost: frame 2's 3 and 4, frame 3's 0 and 1.
        var e = push(&a, Array(f2.prefix(3)), at: t(20))
        e += push(&a, [f3[2]], at: t(36))
        XCTAssertEqual(nacks(e), [Nack(frame: 2, indices: [3, 4])], "the end of frame 2 at once")
        e = push(&a, [f3[3], f3[4]], at: t(36.1))
        e += a.tick(nowNs: t(37.1), rttNs: 2 * Self.ms)
        XCTAssertEqual(nacks(e), [Nack(frame: 3, indices: [0, 1])])
        // Frame 3's resends come first: it waits for frame 2.
        XCTAssertEqual(out(push(&a, [f3[0], f3[1]], at: t(38))), [])
        XCTAssertEqual(out(push(&a, [f2[3], f2[4]], at: t(38.5))), [2, 3])
        XCTAssertEqual(a.counts.framesRepaired, 2)
        XCTAssertEqual(a.counts.fragmentsRecovered, 4)
    }

    // MARK: Review Focus 2

    func testAResendAfterGiveUpOrTwiceIsIgnored() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: true)
        _ = push(&a, [f2[0], f2[1], f2[3], f2[4]], at: t(20))
        _ = a.tick(nowNs: t(21), rttNs: 2 * Self.ms)
        let gaveUp = a.tick(nowNs: t(51), rttNs: 2 * Self.ms)
        XCTAssertEqual(refreshes(gaveUp), 1)
        XCTAssertEqual(push(&a, [f2[2]], at: t(52)), [], "a resend after give-up")
        XCTAssertEqual(push(&a, [f2[2]], at: t(53)), [], "and again")
        XCTAssertEqual(out(push(&a, f3, at: t(60))), [3])
        XCTAssertEqual(push(&a, [f3[1]], at: t(61)), [], "a duplicate of a frame already out")
        XCTAssertEqual(push(&a, [f2[4]], at: t(62)), [])
        XCTAssertEqual(a.counts.framesGivenUp, 1)
        XCTAssertEqual(a.counts.refreshes, 1)
    }

    /// A fragment of a frame given up within 200 ms is late (`fragmentsLate`, the frame marked late); one after that,
    /// or of a frame put out, is not counted.
    func testFragmentsForAFrameJustGivenUpCountAsLate() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: true)
        _ = push(&a, [f2[0], f2[1], f2[3], f2[4]], at: t(20))
        _ = a.tick(nowNs: t(21), rttNs: 2 * Self.ms)
        XCTAssertEqual(refreshes(a.tick(nowNs: t(51), rttNs: 2 * Self.ms)), 1)
        XCTAssertEqual(a.givenUp.map(\.frame), [2])
        XCTAssertEqual(a.givenUp.first?.missingSinceNs, t(20))
        _ = push(&a, [f2[2]], at: t(90))
        _ = push(&a, [f2[2]], at: t(95))
        XCTAssertEqual(a.counts.fragmentsLate, 2)
        XCTAssertEqual(a.givenUp.first?.late, true)
        _ = push(&a, f3, at: t(100))
        _ = push(&a, [f3[1]], at: t(101))
        _ = push(&a, [f2[4]], at: t(300))
        XCTAssertEqual(a.counts.fragmentsLate, 2, "a duplicate of a frame put out, or a fragment 250 ms after the give-up")
    }

    /// A give-up settles (counts for the rate) 150 ms after it, once, unless a late fragment came first.
    func testAGiveUpSettlesAfter150msUnlessAFragmentCameLate() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: true), f4 = frags(4, key: false)
        _ = push(&a, [f2[0], f2[1], f2[3], f2[4]], at: t(20))
        _ = a.tick(nowNs: t(21), rttNs: 2 * Self.ms)
        _ = a.tick(nowNs: t(51), rttNs: 2 * Self.ms)
        XCTAssertEqual(a.settledGiveUps(nowNs: t(150)), 0, "99 ms after the give-up")
        XCTAssertEqual(a.settledGiveUps(nowNs: t(201)), 1)
        XCTAssertEqual(a.settledGiveUps(nowNs: t(260)), 0, "counted once")
        _ = push(&a, f3, at: t(300))
        _ = push(&a, [f4[0], f4[1], f4[3], f4[4]], at: t(316))
        _ = a.tick(nowNs: t(317), rttNs: 2 * Self.ms)
        _ = a.tick(nowNs: t(347), rttNs: 2 * Self.ms)
        _ = push(&a, [f4[2]], at: t(380))  // late, not lost
        XCTAssertEqual(a.settledGiveUps(nowNs: t(600)), 0, "a late fragment cancels the give-up")
        XCTAssertEqual(a.counts.framesGivenUp, 2)
    }

    func testARepairedFrameIsNotPutOutTwice() {
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, [f2[0], f2[2], f2[3], f2[4]], at: t(20))
        _ = a.tick(nowNs: t(21), rttNs: 2 * Self.ms)
        XCTAssertEqual(out(push(&a, [f2[1]], at: t(22))), [2])
        XCTAssertEqual(push(&a, [f2[1]], at: t(23)), [])
        XCTAssertEqual(a.tick(nowNs: t(40), rttNs: 2 * Self.ms), [])
    }

    // MARK: reordering

    func testASwapInsideAFrameSendsNoNack() {
        var a = started()
        let f2 = frags(2, key: false)
        var e = push(&a, [f2[0], f2[2]], at: t(20))
        e += push(&a, [f2[1]], at: t(20.5))
        e += a.tick(nowNs: t(21.2), rttNs: 2 * Self.ms)
        e += push(&a, [f2[3], f2[4]], at: t(21.3))
        XCTAssertEqual(out(e), [2])
        XCTAssertEqual(nacks(e), [])
        XCTAssertEqual(a.counts.nacksSent, 0)
        XCTAssertEqual(a.counts.framesRepaired, 0)
    }

    func testASwapAcrossTwoFramesAsksOnceAndEachFrameComesOutOnce() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: false)
        var e = push(&a, Array(f2.prefix(4)), at: t(20))
        e += push(&a, [f3[0]], at: t(20.1))
        XCTAssertEqual(nacks(e), [Nack(frame: 2, indices: [4])], "a later frame shows the earlier one incomplete")
        e = push(&a, [f2[4]], at: t(20.3))              // the original, late
        e += push(&a, Array(f3.dropFirst()), at: t(20.4))
        e += push(&a, [f2[4]], at: t(21))               // the resend
        e += a.tick(nowNs: t(40), rttNs: 2 * Self.ms)
        XCTAssertEqual(out(e), [2, 3])
        XCTAssertEqual(nacks(e), [])
        XCTAssertEqual(a.counts.nacksSent, 1)
    }

    // MARK: timing

    func testRetriesAndGiveUpWithAShortRoundTrip() {
        let rtt = 2 * Self.ms  // retry 8 ms, give up 1 + 2 x 8 + 2 + 5 = 24 ms
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, [f2[0], f2[1], f2[3], f2[4]], at: t(10))
        var nackTimes: [Double] = []
        var refreshAt: Double?
        for step in UInt64(0)...600 {
            let now = 10 + Double(step) / 10
            let e = a.tick(nowNs: 10 * Self.ms + step * Self.ms / 10, rttNs: rtt)
            if !nacks(e).isEmpty { nackTimes.append(now) }
            if refreshes(e) > 0, refreshAt == nil { refreshAt = now }
        }
        XCTAssertEqual(nackTimes.map { ($0 * 10).rounded() / 10 }, [11, 19, 27], "three asks, 8 ms apart")
        XCTAssertEqual(refreshAt.map { ($0 * 10).rounded() / 10 }, 34, "given up 24 ms after it was seen missing")
        XCTAssertEqual(a.counts.framesGivenUp, 1)
    }

    func testTheGiveUpLeavesRoomForEveryAsk() {
        let ms = Self.ms
        XCTAssertEqual(FrameAssembler.giveUpNs(rttNs: 1 * ms), 23 * ms)
        XCTAssertEqual(FrameAssembler.giveUpNs(rttNs: 4 * ms), 26 * ms)
        XCTAssertEqual(FrameAssembler.giveUpNs(rttNs: 8 * ms), 46 * ms)
        XCTAssertEqual(FrameAssembler.giveUpNs(rttNs: 20 * ms), 50 * ms, "the cap")
    }

    func testRetriesAndGiveUpWithALongRoundTrip() {
        let rtt = 30 * Self.ms  // retry 60 ms, give up min(1 + 120 + 30 + 5, 50) = 50 ms
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, [f2[0], f2[1], f2[3], f2[4]], at: t(10))
        var nackTimes: [Double] = []
        var refreshAt: Double?
        for step in UInt64(0)...1000 {
            let now = 10 + Double(step) / 10
            let e = a.tick(nowNs: 10 * Self.ms + step * Self.ms / 10, rttNs: rtt)
            if !nacks(e).isEmpty { nackTimes.append(now) }
            if refreshes(e) > 0, refreshAt == nil { refreshAt = now }
        }
        XCTAssertEqual(nackTimes.map { ($0 * 10).rounded() / 10 }, [11])
        XCTAssertEqual(refreshAt.map { ($0 * 10).rounded() / 10 }, 60)
    }

    func testAskingForANewHoleDoesNotPushTheRetryBack() {
        var a = started()
        let f2 = frags(2, key: false, 8)
        _ = push(&a, [f2[0], f2[1], f2[3]], at: t(10))
        XCTAssertEqual(nacks(a.tick(nowNs: t(11), rttNs: 2 * Self.ms)), [Nack(frame: 2, indices: [2])])
        _ = push(&a, [f2[4], f2[5], f2[7]], at: t(14))
        XCTAssertEqual(nacks(a.tick(nowNs: t(15), rttNs: 2 * Self.ms)), [Nack(frame: 2, indices: [6])])
        XCTAssertEqual(nacks(a.tick(nowNs: t(19), rttNs: 2 * Self.ms)), [Nack(frame: 2, indices: [2, 6])],
                       "the retry is 8 ms after the first ask")
    }

    func testNothingAfterAGivenUpFrameComesOutUntilAKeyFrame() {
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, [f2[0], f2[1], f2[3], f2[4]], at: t(10))
        var e = a.tick(nowNs: t(11), rttNs: 2 * Self.ms)
        e += a.tick(nowNs: t(34), rttNs: 2 * Self.ms)
        guard case let .refresh(lastGood)? = e.last else { return XCTFail("\(e)") }
        XCTAssertEqual(lastGood, 1)
        e = push(&a, frags(3, key: false), at: t(43))
        e += push(&a, frags(4, key: false), at: t(50))
        XCTAssertEqual(out(e), [])
        XCTAssertEqual(refreshes(e), 0, "one refresh per wait")
        XCTAssertEqual(nacks(e), [], "frames that cannot be decoded are not asked for")
        XCTAssertEqual(out(push(&a, frags(5, key: true), at: t(67))), [5])
        XCTAssertEqual(out(push(&a, frags(6, key: false), at: t(83))), [6])
    }

    func testTheTimerIsDueOnlyWhileSomethingIsMissing() {
        var a = started()
        XCTAssertNil(a.nextTickNs(rttNs: 2 * Self.ms))
        let f2 = frags(2, key: false)
        _ = push(&a, [f2[0], f2[2], f2[4]], at: t(10))
        XCTAssertEqual(a.nextTickNs(rttNs: 2 * Self.ms), t(11))
        _ = a.tick(nowNs: t(11), rttNs: 2 * Self.ms)
        XCTAssertEqual(a.nextTickNs(rttNs: 2 * Self.ms), t(19), "the retry")
        _ = push(&a, Array(f2[1...]), at: t(12))
        XCTAssertNil(a.nextTickNs(rttNs: 2 * Self.ms))
    }

    // MARK: restart

    func testRestartForgetsTheOldStreamAndItsHoles() {
        var a = started()
        for n in UInt32(2)...50 { _ = push(&a, frags(n, key: false), at: t(Double(n) * 16)) }
        let f51 = frags(51, key: false)
        _ = push(&a, [f51[0], f51[3]], at: t(900))
        a.restart()
        XCTAssertEqual(a.counts, AssemblerCounts())
        XCTAssertNil(a.nextTickNs(rttNs: 2 * Self.ms))
        XCTAssertEqual(a.tick(nowNs: t(905), rttNs: 2 * Self.ms), [], "no nack for the old stream's frame")
        XCTAssertEqual(out(push(&a, frags(0, key: true), at: t(910))), [0])
        XCTAssertEqual(out(push(&a, frags(1, key: false), at: t(926))), [1])
        XCTAssertEqual(a.tick(nowNs: t(1000), rttNs: 2 * Self.ms), [])
    }

    // MARK: key frames (rules kept from before)

    func testTheFirstFrameMustBeAKeyFrame() {
        var a = FrameAssembler()
        let f = frags(7, key: false)
        XCTAssertEqual(a.push(f[0], nowNs: 0), [.refresh(lastGood: nil)])
        XCTAssertEqual(a.push(f[1], nowNs: 0), [])
        XCTAssertEqual(push(&a, frags(8, key: false), at: t(16)), [])
        XCTAssertEqual(out(push(&a, frags(9, key: true), at: t(32))), [9])
    }

    func testAwaitKeyframeDropsDeltasUntilKey() {
        var a = started()
        XCTAssertEqual(out(push(&a, frags(2, key: false), at: t(16))), [2])
        a.awaitKeyframe()
        XCTAssertEqual(push(&a, frags(3, key: false), at: t(32)), [], "the caller asked: no refresh event")
        XCTAssertEqual(push(&a, frags(4, key: false), at: t(48)), [])
        XCTAssertEqual(out(push(&a, frags(5, key: true), at: t(64))), [5])
        XCTAssertEqual(out(push(&a, frags(6, key: false), at: t(80))), [6])
    }

    func testDeltasAfterAnIncompleteKeyFrameWaitForIt() {
        var a = FrameAssembler()
        let k = frags(1, key: true, 20)
        var e = push(&a, Array(k.prefix(10)) + Array(k.suffix(8)), at: 0)
        e += push(&a, frags(2, key: false), at: t(16))
        XCTAssertEqual(nacks(e), [Nack(frame: 1, indices: [10, 11])])
        XCTAssertEqual(out(push(&a, [k[10], k[11]], at: t(17))), [1, 2])
    }

    func testACompleteKeyFrameIsNotHeldBehindAnIncompleteFrame() {
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, [f2[0], f2[1]], at: t(16))
        XCTAssertEqual(out(push(&a, frags(3, key: true), at: t(32))), [3])
        XCTAssertEqual(push(&a, Array(f2[2...]), at: t(33)), [])
    }

    func testShuffledKeyFrame() {
        var a = FrameAssembler()
        var g = SystemRandomNumberGenerator()
        let fs = frags(1, key: true, 44).shuffled(using: &g)
        let e = push(&a, fs, at: 0)
        XCTAssertEqual(out(e), [1])
        guard case let .frame(f)? = e.last else { return XCTFail() }
        XCTAssertEqual(f.data, data(1, 44))
    }

    func testDuplicatesAndOld() {
        var a = started()
        let f4 = frags(4, key: true)
        XCTAssertEqual(out(a.push(f4[0], nowNs: t(50))), [])
        XCTAssertEqual(out(a.push(f4[0], nowNs: t(50))), [])
        XCTAssertEqual(a.push(frags(1, key: true)[0], nowNs: t(50)), [])
        let e = push(&a, Array(f4.dropFirst()), at: t(51))
        XCTAssertEqual(out(e), [4])
    }

    // MARK: hostile or broken input

    func testOversizedFrameIsGivenUpAndItsFragmentsIgnored() {
        var a = FrameAssembler()
        let big = VideoFragment(frame: 1, index: 0, count: 8000, key: true, captureNs: 0, width: 1, height: 1, payload: Data([1]))
        XCTAssertEqual(a.push(big, nowNs: 0), [.refresh(lastGood: nil)])
        var next = big; next.index = 1
        XCTAssertEqual(a.push(next, nowNs: 0), [])
        XCTAssertFalse(a.hasFrameInAssembly)
    }

    func testMismatchedCountGivesTheFrameUp() {
        var a = started()
        let a0 = VideoFragment(frame: 2, index: 0, count: 3, key: true, captureNs: 0, width: 1, height: 1, payload: Data([1]))
        var a1 = a0; a1.index = 1; a1.count = 4
        XCTAssertEqual(a.push(a0, nowNs: t(16)), [])
        XCTAssertEqual(a.push(a1, nowNs: t(16)), [.refresh(lastGood: 1)])
        XCTAssertFalse(a.hasFrameInAssembly)
    }

    func testAFrameFarAheadIsBoundedWork() {
        var a = started()
        let far = frags(1_000_000, key: false)
        let e = push(&a, far, at: t(16))
        XCTAssertEqual(out(e), [])
        XCTAssertEqual(refreshes(e), 1)
        XCTAssertEqual(nacks(e), [], "frames beyond the window are not asked for")
        XCTAssertLessThanOrEqual(a.windowCount, FrameAssembler.window)
        XCTAssertEqual(out(push(&a, frags(1_000_001, key: true), at: t(32))), [1_000_001])
    }

    func testAGapOfSevenIsAskedForWholeAndRepaired() {
        var a = started()
        var e = push(&a, frags(9, key: false), at: t(16))
        XCTAssertEqual(nacks(e), (UInt32(2)...8).map { Nack(frame: $0, indices: []) })
        XCTAssertEqual(refreshes(e), 0)
        for n in UInt32(2)...8 { e += push(&a, frags(n, key: false), at: t(18)) }
        XCTAssertEqual(out(e), Array(2...9))
        XCTAssertEqual(a.counts.framesRepaired, 7)
    }

    func testAGapWiderThanTheWindowGivesUpOnce() {
        var a = started()
        let e = push(&a, [frags(2, key: true)[0]], at: t(16)) + push(&a, [frags(30, key: false)[0]], at: t(17))
        XCTAssertEqual(refreshes(e), 1)
        XCTAssertEqual(nacks(e), [])
        XCTAssertLessThanOrEqual(a.windowCount, FrameAssembler.window)
    }

    func testABrokenFragmentFarAheadIsIgnored() {
        var a = started()
        let bad = VideoFragment(frame: 0xFFFF_FFF0, index: 0, count: 8000, key: false, captureNs: 0, width: 1, height: 1,
                                payload: Data([1]))
        XCTAssertEqual(a.push(bad, nowNs: t(10)), [])
        XCTAssertEqual(out(push(&a, frags(2, key: false), at: t(16))), [2])
        XCTAssertEqual(out(push(&a, frags(3, key: false), at: t(32))), [3])
        XCTAssertEqual(a.counts.framesGivenUp, 0)
    }

    /// A fresh assembler (nothing held, no floor) given one malformed far-ahead fragment still takes the stream's frames.
    func testABrokenFragmentFarAheadOfAFreshAssemblerIsIgnored() {
        var a = FrameAssembler()
        let bad = VideoFragment(frame: 0xFFFF_FFF0, index: 0, count: 8000, key: false, captureNs: 0, width: 1, height: 1,
                                payload: Data([1]))
        XCTAssertEqual(a.push(bad, nowNs: t(10)), [])
        XCTAssertEqual(out(push(&a, frags(1, key: true), at: t(16))), [1], "the stream froze behind the bad fragment")
        XCTAssertEqual(a.counts.framesGivenUp, 0)
    }

    /// A fragment of a given-up frame stamped before the give-up (a caller's clock that went back) is not late and no trap.
    func testALateFragmentWithAnEarlierClockIsIgnored() {
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, [f2[0], f2[1], f2[3], f2[4]], at: t(20))
        _ = a.tick(nowNs: t(21), rttNs: 2 * Self.ms)
        XCTAssertEqual(refreshes(a.tick(nowNs: t(51), rttNs: 2 * Self.ms)), 1)
        _ = push(&a, [f2[2]], at: t(30))
        XCTAssertEqual(a.counts.fragmentsLate, 0)
    }

    /// Awaiting a key frame, its first fragment arrives after a later frame's: its tail is known missing at once.
    func testAFrameInsertedBelowTheNewestHasItsTailKnown() {
        var a = started()
        a.awaitKeyframe()
        let k = frags(5, key: true), f6 = frags(6, key: false)
        var e = push(&a, [k[0]], at: t(10))
        e += push(&a, Array(f6.prefix(1)), at: t(11))   // frame 5's tail is known: 1...4 asked
        XCTAssertEqual(nacks(e), [Nack(frame: 5, indices: [1, 2, 3, 4])])
        let k4 = frags(4, key: true)
        e = push(&a, [k4[1]], at: t(12))                 // an older key frame, inserted below 5
        XCTAssertEqual(nacks(e), [Nack(frame: 4, indices: [0, 2, 3, 4])])
    }

    func testALostTailIsAskedForAfterAQuietSpell() {
        var a = started()
        let f2 = frags(2, key: false)
        XCTAssertEqual(push(&a, Array(f2.prefix(3)), at: t(20)), [])
        XCTAssertEqual(a.nextTickNs(rttNs: 2 * Self.ms), t(24))
        XCTAssertEqual(a.tick(nowNs: t(23.9), rttNs: 2 * Self.ms), [])
        XCTAssertEqual(nacks(a.tick(nowNs: t(24), rttNs: 2 * Self.ms)), [Nack(frame: 2, indices: [3, 4])])
        XCTAssertEqual(out(push(&a, [f2[3], f2[4]], at: t(25))), [2])
    }

    /// A stall holds everything: the quiet tail is asked for, but only a later frame starts the give-up clock.
    func testAQuietTailIsNotGivenUpDuringAStall() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: false)
        _ = push(&a, Array(f2.prefix(3)), at: t(20))
        var e: [AssemblerEvent] = []
        for ms in stride(from: 21.0, through: 100, by: 1) { e += a.tick(nowNs: t(ms), rttNs: 2 * Self.ms, heardNs: t(20)) }
        XCTAssertEqual(nacks(e), [], "nothing was heard since the frame's last fragment: the radio is stalled, not the tail lost")
        XCTAssertEqual(refreshes(e), 0, "given up during the stall")
        e = push(&a, Array(f2.suffix(2)) + f3, at: t(101))   // all at once after the stall
        XCTAssertEqual(out(e), [2, 3])
        XCTAssertEqual(a.counts.framesGivenUp, 0)
    }

    /// A radio stall is silence from everything: 60 ms without any Host datagram, then the tail arrives: no nack.
    func testNothingIsAskedForDuringAStallAndTheTailArrivingAfterwardsIsNotAskedFor() {
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, Array(f2.prefix(3)), at: t(20))
        XCTAssertEqual(a.nextTickNs(rttNs: 2 * Self.ms, heardNs: t(20)), nil, "no timer: only a datagram can wake it")
        XCTAssertEqual(a.tick(nowNs: t(80), rttNs: 2 * Self.ms, heardNs: t(20)), [])
        var e = push(&a, [f2[3]], at: t(80))
        e += a.tick(nowNs: t(80), rttNs: 2 * Self.ms, heardNs: t(80))
        e += push(&a, [f2[4]], at: t(80.1))
        XCTAssertEqual(nacks(e), [])
        XCTAssertEqual(out(e), [2])
    }

    /// Some other Host datagram (a sound block) 5 ms after the last fragment: the link is alive, the tail is lost.
    func testAnyHostDatagramAfterTheQuietSpellMakesTheTailAskedFor() {
        var a = started()
        let f2 = frags(2, key: false)
        _ = push(&a, Array(f2.prefix(3)), at: t(20))
        XCTAssertEqual(a.tick(nowNs: t(22), rttNs: 2 * Self.ms, heardNs: t(21)), [], "heard only 1 ms after: not yet")
        XCTAssertEqual(nacks(a.tick(nowNs: t(25), rttNs: 2 * Self.ms, heardNs: t(25))), [Nack(frame: 2, indices: [3, 4])])
    }

    /// A later frame's fragment asks at once (the stall is over and the tail is known missing).
    func testALaterFramesFragmentStillAsksAtOnceAfterASilence() {
        var a = started()
        let f2 = frags(2, key: false), f3 = frags(3, key: false)
        _ = push(&a, Array(f2.prefix(3)), at: t(20))
        XCTAssertEqual(nacks(push(&a, [f3[0]], at: t(80))), [Nack(frame: 2, indices: [3, 4])])
    }

    func testFragmentsInFlightAreNotATail() {
        var a = started()
        let f2 = frags(2, key: false)
        var e: [AssemblerEvent] = []
        for (i, f) in f2.enumerated() {
            e += push(&a, [f], at: t(20 + Double(i) * 3))  // 3 ms apart: never 4 ms quiet
            e += a.tick(nowNs: t(20 + Double(i) * 3 + 2.9), rttNs: 2 * Self.ms)
        }
        XCTAssertEqual(out(e), [2])
        XCTAssertEqual(nacks(e), [])
    }

    /// Constant work per fragment (Debug build): a 5 000-fragment frame pushed in order. Measured: 1 100 ms when each
    /// fragment scanned the frame and copied its slots, 4.5 ms after; the bound leaves room for a busy Mac.
    func testALargeFrameCostsConstantWorkPerFragment() {
        var a = FrameAssembler()
        let fs = frags(1, key: true, 5000)
        let start = DispatchTime.now().uptimeNanoseconds
        let e = push(&a, fs, at: 0)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("assembler: 5000 fragments in \(ms) ms")
        XCTAssertEqual(out(e), [1])
        XCTAssertLessThan(ms, 100)
    }

    func testAssemblesFrameAboveFourMiB() {
        var a = FrameAssembler()
        let d = bytes(5 << 20, seed: 3)
        let fs = FrameSplitter.split(frame: 1, key: true, captureNs: 1, width: 2, height: 2, data: d)
        let e = push(&a, fs, at: 0)
        guard case let .frame(f)? = e.last else { return XCTFail("not assembled") }
        XCTAssertEqual(f.data, d)
    }
    // MARK: repair frames -> .claude/portalkit.md § video

    private func repairFrags(_ frame: UInt32, _ n: Int = 5) -> [VideoFragment] {
        FrameSplitter.split(frame: frame, key: false, repair: true, captureNs: 99, width: 1280, height: 720,
                            data: bytes(n * Wire.maxVideoPayload - 100, seed: frame))
    }

    /// Frames 1...3 out, frame 4 loses a fragment and is given up: one restart asked for; 5 and 6 (ordinary, still in
    /// flight) are dropped and counted, never given up one by one; the repair frame 7 restarts the output, and 8 follows.
    func testARepairFrameRestartsTheOutputAfterAGivenUpFrame() {
        var a = started()
        a.acceptsRepair = true
        var e = push(&a, frags(2, key: false) + frags(3, key: false), at: t(17))
        XCTAssertEqual(out(e), [2, 3])
        e = push(&a, Array(frags(4, key: false).dropLast()), at: t(34))
        e += push(&a, frags(5, key: false), at: t(51))
        e += a.tick(nowNs: t(51) + FrameAssembler.giveUpNs(rttNs: 2 * Self.ms) + 1, rttNs: 2 * Self.ms)
        XCTAssertEqual(refreshes(e), 1)
        XCTAssertEqual(a.counts.framesGivenUp, 1, "only the frame that was given up")
        e = push(&a, frags(6, key: false), at: t(68))
        e += push(&a, repairFrags(7), at: t(85))
        e += push(&a, frags(8, key: false), at: t(102))
        XCTAssertEqual(out(e), [7, 8])
        XCTAssertEqual(refreshes(e), 0, "no second restart asked for")
        let restart = e.compactMap { if case let .frame(f) = $0 { f } else { nil } }.first
        XCTAssertEqual(restart?.repair, true)
        XCTAssertEqual(restart?.key, false)
        XCTAssertEqual(a.counts.restartsAtRepair, 1)
        XCTAssertEqual(a.counts.framesGivenUp, 1)
        XCTAssertEqual(a.counts.framesWaited, 2, "5 and 6 dropped while waiting")
    }

    /// A repair frame complete in the window before the frames ahead of it: it does not wait for them.
    func testACompleteRepairFrameSkipsTheIncompleteFramesBeforeItWhileWaiting() {
        var a = started()
        a.acceptsRepair = true
        var e = push(&a, Array(frags(2, key: false).dropLast()), at: t(17))
        e += push(&a, frags(3, key: false), at: t(34))
        e += a.tick(nowNs: t(34) + FrameAssembler.giveUpNs(rttNs: 2 * Self.ms) + 1, rttNs: 2 * Self.ms)
        XCTAssertEqual(refreshes(e), 1)
        e = push(&a, Array(frags(4, key: false).dropLast()), at: t(51))
        e += push(&a, repairFrags(5), at: t(68))
        XCTAssertEqual(out(e), [5])
        XCTAssertEqual(a.counts.restartsAtRepair, 1)
    }

    /// Without `acceptsRepair` (no key frame decoded since the decoder started or failed) a repair frame is an ordinary
    /// frame: the output waits for a key frame.
    func testARepairFrameIsNoRestartPointUntilTheCallerAcceptsOne() {
        var a = started()
        var e = push(&a, Array(frags(2, key: false).dropLast()), at: t(17))
        e += push(&a, frags(3, key: false), at: t(34))
        e += a.tick(nowNs: t(34) + FrameAssembler.giveUpNs(rttNs: 2 * Self.ms) + 1, rttNs: 2 * Self.ms)
        e += push(&a, repairFrags(4), at: t(51))
        e += push(&a, frags(5, key: false), at: t(68))
        XCTAssertEqual(out(e), [])
        e = push(&a, frags(6, key: true), at: t(85))
        XCTAssertEqual(out(e), [6])
        XCTAssertEqual(a.counts.restartsAtRepair, 0)
    }

    /// `awaitKeyframe` (the caller asked for a key frame: a decode failed, a stall, an escalation) makes repair frames
    /// no restart point again, the one already held in the window included.
    func testAwaitingAKeyFrameRefusesRepairFrames() {
        var a = started()
        a.acceptsRepair = true
        var e = push(&a, Array(frags(2, key: false).dropLast()), at: t(17))
        e += push(&a, frags(3, key: false), at: t(34))
        e += a.tick(nowNs: t(34) + FrameAssembler.giveUpNs(rttNs: 2 * Self.ms) + 1, rttNs: 2 * Self.ms)
        e += push(&a, Array(repairFrags(4).dropLast()), at: t(51))
        a.awaitKeyframe()
        XCTAssertFalse(a.acceptsRepair)
        e += push(&a, Array(repairFrags(4).suffix(1)), at: t(52))
        e += push(&a, frags(5, key: false), at: t(68))
        XCTAssertEqual(out(e), [])
        e = push(&a, frags(6, key: true), at: t(85))
        XCTAssertEqual(out(e), [6])
    }

    /// Out of a wait, a repair frame is the next frame like any other (in order, marked).
    func testARepairFrameInOrderIsAnOrdinaryFrame() {
        var a = started()
        a.acceptsRepair = true
        let e = push(&a, repairFrags(2) + frags(3, key: false), at: t(17))
        XCTAssertEqual(out(e), [2, 3])
        XCTAssertEqual(a.counts.restartsAtRepair, 0)
    }
}
