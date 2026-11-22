import XCTest
import PortalKit
@testable import PortalClientCore

/// Synthetic times only: the tracker has no clock of its own.
final class StatsTests: XCTestCase {
    private let ms: UInt64 = 1_000_000, sec: UInt64 = 1_000_000_000

    private func frame(_ n: UInt32, capture: UInt64 = 0, key: Bool = false) -> AssembledFrame {
        AssembledFrame(frame: n, key: key, captureNs: capture, width: 16, height: 16, data: Data())
    }

    /// A pong whose round trip is `rtt` and whose offset (host minus local midpoint) is `offset`.
    private func pong(_ t: inout StatsTracker, send: UInt64, rtt: UInt64, offset: Int64) {
        let host = Int64(send + rtt / 2) + offset
        t.pong(sendNs: send, receiveNs: send + rtt, hostNs: UInt64(host))
    }

    /// A pong echoing a time later than now (a hostile or confused peer) is ignored: no trap, no sample.
    func testAPongFromTheFutureIsIgnored() {
        var t = StatsTracker(startNs: 0)
        t.pong(sendNs: 5_000_000_000, receiveNs: 1_000_000_000, hostNs: 7)
        XCTAssertNil(t.clockOffsetNs)
    }

    /// A tracker whose clock offset is known (0): delay samples count from here on.
    private func synced() -> StatsTracker {
        var t = StatsTracker(startNs: 0)
        pong(&t, send: 0, rtt: 0, offset: 0)
        return t
    }

    func testTheNewestHostStatsAreKept() {
        var t = StatsTracker(startNs: 0)
        XCTAssertNil(t.snapshot(nowNs: sec).host)
        t.hostStats(HostStats(framesFromGame: 10, framesSent: 9, framesDropped: 1, resent: 2, rateBps: 5_000_000))
        t.hostStats(HostStats(framesFromGame: 70, framesSent: 69, framesDropped: 1, resent: 5, rateBps: 6_000_000, sendLateMaxUs: 900))
        XCTAssertEqual(t.snapshot(nowNs: 2 * sec).host, HostStats(framesFromGame: 70, framesSent: 69, framesDropped: 1, resent: 5, rateBps: 6_000_000, sendLateMaxUs: 900))
    }

    func testOffsetFromSmallestRoundTrip() {
        var t = StatsTracker(startNs: 0)
        pong(&t, send: 1 * sec, rtt: 8 * ms, offset: 7_000)
        pong(&t, send: 2 * sec, rtt: 2 * ms, offset: 5_000)
        pong(&t, send: 3 * sec, rtt: 20 * ms, offset: 9_000)
        XCTAssertEqual(t.stats.clockOffsetNs, 5_000)
    }

    func testOffsetWindowDropsTheOldestPong() {
        var t = StatsTracker(startNs: 0)
        pong(&t, send: 1 * sec, rtt: 1 * ms, offset: 111)
        for i in 0..<24 { pong(&t, send: UInt64(2 + i) * sec, rtt: 5 * ms, offset: 222) }
        XCTAssertEqual(t.stats.clockOffsetNs, 111, "still inside the 25-pong window")
        pong(&t, send: 26 * sec, rtt: 5 * ms, offset: 222)
        XCTAssertEqual(t.stats.clockOffsetNs, 222, "the smallest round trip fell out")
    }

    func testHostClockAheadGivesPositiveOffsetAndDelay() {
        var t = StatsTracker(startNs: 0)
        pong(&t, send: 10 * sec, rtt: 2 * ms, offset: 5_000_000_000)
        XCTAssertEqual(t.stats.clockOffsetNs, 5_000_000_000)
        // Captured at host time 15.001 s; arrives at local 10.004 s = host 15.004 s: 3 ms.
        t.frameShown(frame(1, capture: 15 * sec + ms), arrivalNs: 10 * sec + 4 * ms)
        XCTAssertEqual(t.snapshot(nowNs: 10 * sec + 5 * ms).p95DelayMs, 3, accuracy: 0.001)
    }

    func testP95OfKnownList() {
        var t = synced()
        for i in 1...100 { t.frameShown(frame(UInt32(i), capture: 0), arrivalNs: UInt64(i) * ms) }
        XCTAssertEqual(t.snapshot(nowNs: sec).p95DelayMs, 95, accuracy: 0.001)
    }

    func testDelayWindowKeepsTheLast600() {
        var t = synced()
        for i in 1...700 { t.frameShown(frame(UInt32(i), capture: 0), arrivalNs: UInt64(i < 101 ? 1000 : 1) * ms) }
        // The first 100 frames (1000 ms) fell out of the window: only 1 ms delays remain.
        XCTAssertEqual(t.snapshot(nowNs: sec).p95DelayMs, 1, accuracy: 0.001)
    }

    /// A device's uptime clock differs from the Mac's: with no pong yet the offset is unknown, so no delay sample is kept.
    func testDelaysSkippedUntilFirstPong() {
        var t = StatsTracker(startNs: 0)
        t.frameShown(frame(1, capture: 0), arrivalNs: 900 * sec)
        t.displayed(captureNs: 0, nowNs: 900 * sec)
        var s = t.snapshot(nowNs: 900 * sec)
        XCTAssertEqual(s.framesShown, 1, "the frame still counts")
        XCTAssertEqual(s.p95DelayMs, 0, "arrival delay sampled before the first pong")
        XCTAssertEqual(s.p95DisplayMs, 0, "display delay sampled before the first pong")
        pong(&t, send: 10 * sec, rtt: 2 * ms, offset: 0)
        t.frameShown(frame(2, capture: 10 * sec), arrivalNs: 10 * sec + 3 * ms)
        t.displayed(captureNs: 10 * sec, nowNs: 10 * sec + 4 * ms)
        s = t.snapshot(nowNs: 10 * sec + 5 * ms)
        XCTAssertEqual(s.p95DelayMs, 3, accuracy: 0.001)
        XCTAssertEqual(s.p95DisplayMs, 4, accuracy: 0.001)
    }

    func testFramesSkippedCountsGaps() {
        var t = StatsTracker(startNs: 0)
        for n: UInt32 in [5, 6, 7, 10, 11, 20] { t.frameShown(frame(n), arrivalNs: 0) }
        XCTAssertEqual(t.stats.framesShown, 6)
        XCTAssertEqual(t.stats.framesSkipped, 2 + 8)
    }

    func testAudioDuplicateOlderAndGap() {
        var t = StatsTracker(startNs: 0)
        XCTAssertTrue(t.audioArrived(seq: 100))
        XCTAssertTrue(t.audioArrived(seq: 101))
        XCTAssertFalse(t.audioArrived(seq: 101), "duplicate")
        XCTAssertFalse(t.audioArrived(seq: 99), "older")
        XCTAssertEqual(t.stats.audioLost, 0)
        XCTAssertTrue(t.audioArrived(seq: 105))
        XCTAssertEqual(t.stats.audioLost, 3)
        XCTAssertFalse(t.audioArrived(seq: 102), "late block is dropped, not counted twice")
        XCTAssertEqual(t.stats.audioLost, 3)
    }

    func testFpsWindow() {
        var t = StatsTracker(startNs: 0)
        for i in 0..<60 { t.frameShown(frame(UInt32(i)), arrivalNs: UInt64(i) * 16 * ms) }
        XCTAssertEqual(t.snapshot(nowNs: sec).fps, 60, accuracy: 0.001, "younger than 2 s: by elapsed time")
        XCTAssertEqual(t.snapshot(nowNs: 3 * sec).fps, 0, accuracy: 0.001, "all older than 2 s")
    }

    func testKeyRequestsCounted() {
        var t = StatsTracker(startNs: 0)
        t.keyRequestSent(); t.keyRequestSent()
        XCTAssertEqual(t.stats.keyRequests, 2)
    }

    func testDisplayDelayP95() {
        var t = synced()
        for i in 1...100 { t.displayed(captureNs: 1000 * ms, nowNs: 1000 * ms + UInt64(i) * ms) }
        XCTAssertEqual(t.snapshot(nowNs: 2000 * ms).p95DisplayMs, 95, accuracy: 1)
        // The clock offset applies as it does for arrival delay: host ahead by 5 s.
        var u = StatsTracker(startNs: 0)
        pong(&u, send: 10 * sec, rtt: 2 * ms, offset: 5_000_000_000)
        for i in 1...100 { u.displayed(captureNs: 15 * sec, nowNs: 10 * sec + UInt64(i) * ms) }
        XCTAssertEqual(u.snapshot(nowNs: 11 * sec).p95DisplayMs, 95, accuracy: 1)
        var empty = StatsTracker(startNs: 0)
        XCTAssertEqual(empty.snapshot(nowNs: sec).p95DisplayMs, 0)
    }

    /// Every display mark counts, also before the first pong (only the delay sample waits for the offset).
    func testFramesDisplayedCountsEveryMark() {
        var t = StatsTracker(startNs: 0)
        XCTAssertEqual(t.snapshot(nowNs: sec).framesDisplayed, 0)
        t.displayed(captureNs: 0, nowNs: sec)
        pong(&t, send: 10 * sec, rtt: 2 * ms, offset: 0)
        for i in 1...4 { t.displayed(captureNs: 10 * sec, nowNs: 10 * sec + UInt64(i) * ms) }
        XCTAssertEqual(t.snapshot(nowNs: 11 * sec).framesDisplayed, 5)
        XCTAssertEqual(t.stats.framesShown, 0, "displayed is not shown: no frame was assembled")
    }

    func testDisplayDelayWindowKeepsTheLast600() {
        var t = synced()
        for i in 0..<700 { t.displayed(captureNs: 0, nowNs: (i < 100 ? 1000 : 1) * ms) }
        XCTAssertEqual(t.snapshot(nowNs: sec).p95DisplayMs, 1, accuracy: 0.001)
    }

    func testShownPrunedOnAppend() {
        var t = StatsTracker(startNs: 0)
        for i in 0..<10_000 { t.frameShown(frame(UInt32(i)), arrivalNs: UInt64(i) * sec / 60) }
        XCTAssertLessThanOrEqual(t.shownCount, 121)
        XCTAssertGreaterThan(t.shownCount, 100)
    }

    // MARK: play numbers

    private func sized(_ n: UInt32, bytes: Int = 0, key: Bool = false, w: UInt16 = 16, h: UInt16 = 16) -> AssembledFrame {
        AssembledFrame(frame: n, key: key, captureNs: 0, width: w, height: h, data: Data(count: bytes))
    }

    func testBitrateIsPayloadOfTheLastTwoSeconds() {
        var t = StatsTracker(startNs: 0)
        // 60 frames a second of 5,000 bytes for 4 s = 2.4 Mbit/s; only the last 2 s count.
        for i in 0..<240 { t.frameShown(sized(UInt32(i), bytes: 5_000), arrivalNs: 10 * sec + UInt64(i) * sec / 60) }
        XCTAssertEqual(t.snapshot(nowNs: 14 * sec).bitrateMbps, 2.4, accuracy: 0.05)
        XCTAssertEqual(t.snapshot(nowNs: 20 * sec).bitrateMbps, 0)
    }

    /// 23 pongs (2.3 s at 10 a second), as 9 were at 4 a second.
    func testRoundTripIsMedianOfLastTwentyThree() {
        var t = StatsTracker(startNs: 0)
        XCTAssertEqual(t.snapshot(nowNs: sec).rttMs, 0)
        // 100 ms outlier first, then 23 of 1...23 ms: the outlier is out of the window.
        pong(&t, send: sec, rtt: 100 * ms, offset: 0)
        for i in 1...23 { pong(&t, send: UInt64(1 + i) * sec, rtt: UInt64(i) * ms, offset: 0) }
        XCTAssertEqual(t.snapshot(nowNs: 30 * sec).rttMs, 12, accuracy: 0.001)
    }

    /// The ping floor: the lowest round trip of the pongs that arrived in the last 300 ms; one late pong does not raise
    /// it, one pong alone is no floor.
    func testThePingFloorIsTheLowestOfTheLast300ms() {
        var t = StatsTracker(startNs: 0)
        let base = 10 * sec
        pong(&t, send: base, rtt: 2 * ms, offset: 0)
        XCTAssertNil(t.rttFloorNs(nowNs: base + 2 * ms), "one pong is no floor")
        pong(&t, send: base + 100 * ms, rtt: 40 * ms, offset: 0)  // a radio hiccup
        pong(&t, send: base + 200 * ms, rtt: 3 * ms, offset: 0)
        XCTAssertEqual(t.rttFloorNs(nowNs: base + 210 * ms), 2 * ms)
        // A queue: every pong late.
        for i in 3...6 { pong(&t, send: base + UInt64(i) * 100 * ms, rtt: 30 * ms + UInt64(i) * ms, offset: 0) }
        XCTAssertEqual(t.rttFloorNs(nowNs: base + 640 * ms), 34 * ms)
        XCTAssertNil(t.rttFloorNs(nowNs: base + 2 * sec), "pongs older than 300 ms")
    }

    func testP50DisplayOfKnownList() {
        var t = synced()
        for i in 1...100 { t.displayed(captureNs: 0, nowNs: UInt64(i) * ms) }
        let s = t.snapshot(nowNs: sec)
        XCTAssertEqual(s.p50DisplayMs, 50, accuracy: 1)
        XCTAssertEqual(s.p95DisplayMs, 95, accuracy: 1)
    }

    func testArrivalGapsSteadyAndBunched() {
        var steady = StatsTracker(startNs: 0)
        for i in 0..<120 { steady.frameShown(sized(UInt32(i)), arrivalNs: 10 * sec + UInt64(i) * sec / 60) }
        let a = steady.snapshot(nowNs: 12 * sec)
        XCTAssertEqual(a.p95ArrivalGapMs, 16.7, accuracy: 0.2)
        XCTAssertEqual(a.maxArrivalGapMs, 16.7, accuracy: 0.2)

        // Pairs 33.3 ms apart, 0.5 ms inside a pair.
        var bunched = StatsTracker(startNs: 0)
        for i in 0..<60 {
            let base = 10 * sec + UInt64(i) * sec / 30
            bunched.frameShown(sized(UInt32(2 * i)), arrivalNs: base)
            bunched.frameShown(sized(UInt32(2 * i + 1)), arrivalNs: base + ms / 2)
        }
        let b = bunched.snapshot(nowNs: 12 * sec)
        XCTAssertGreaterThan(b.p95ArrivalGapMs, 30)
        XCTAssertGreaterThan(b.maxArrivalGapMs, 32)
    }

    func testArrivalGapsOnlyLastTwoSecondsAndNotAcrossARestart() {
        var t = StatsTracker(startNs: 0)
        t.frameShown(sized(1), arrivalNs: 10 * sec)
        t.frameShown(sized(2), arrivalNs: 10 * sec + 900 * ms)
        XCTAssertEqual(t.snapshot(nowNs: 11 * sec).maxArrivalGapMs, 900, accuracy: 0.01)
        XCTAssertEqual(t.snapshot(nowNs: 13 * sec).maxArrivalGapMs, 0, "older than 2 s")
        t.videoRestarted()
        t.frameShown(sized(0), arrivalNs: 20 * sec)
        XCTAssertEqual(t.snapshot(nowNs: 20 * sec + ms).maxArrivalGapMs, 0, "a restart is not a gap")
    }

    func testSizeFromNewestKeyFrame() {
        var t = StatsTracker(startNs: 0)
        XCTAssertEqual(t.snapshot(nowNs: sec).width, 0)
        t.frameShown(sized(1, key: true, w: 1920, h: 1080), arrivalNs: sec)
        t.frameShown(sized(2, w: 16, h: 16), arrivalNs: sec + ms)
        var s = t.snapshot(nowNs: 2 * sec)
        XCTAssertEqual(s.width, 1920); XCTAssertEqual(s.height, 1080)
        t.frameShown(sized(3, key: true, w: 1280, h: 720), arrivalNs: sec + 2 * ms)
        s = t.snapshot(nowNs: 2 * sec)
        XCTAssertEqual(s.width, 1280); XCTAssertEqual(s.height, 720)
    }

    /// A game that starts late in a long session: the rates divide by the stream's own span, not the session's age.
    func testRatesRightFromTheStartOfALateStream() {
        var t = StatsTracker(startNs: 0)
        // 30 frames of 5,000 bytes in the first half second of a stream that begins at 100 s.
        for i in 0..<30 { t.frameShown(sized(UInt32(i), bytes: 5_000), arrivalNs: 100 * sec + UInt64(i) * sec / 60) }
        let s = t.snapshot(nowNs: 100 * sec + sec / 2)
        XCTAssertEqual(s.fps, 60, accuracy: 3)
        XCTAssertEqual(s.bitrateMbps, 2.4, accuracy: 0.15)
        // After a restart the origin moves too.
        t.videoRestarted()
        for i in 0..<30 { t.frameShown(sized(UInt32(i), bytes: 5_000), arrivalNs: 200 * sec + UInt64(i) * sec / 60) }
        XCTAssertEqual(t.snapshot(nowNs: 200 * sec + sec / 2).fps, 60, accuracy: 3)
    }

    // MARK: source gaps

    private let period: UInt64 = 1_000_000_000 / 60

    func testSourceGapsCountFramesTheMacNeverSent() {
        var t = StatsTracker(startNs: 0, maxFps: 60)
        var capture: UInt64 = 5 * sec
        var n: UInt32 = 0
        func next(after steps: UInt64) { capture += steps * period / 10; t.frameShown(frame(n, capture: capture), arrivalNs: capture + 3 * ms); n += 1 }
        next(after: 0)
        for _ in 0..<5 { next(after: 10) }  // one period each: steady
        XCTAssertEqual(t.snapshot(nowNs: capture).sourceGaps, 0)
        next(after: 14)  // 1.4 periods: inside the limit
        XCTAssertEqual(t.snapshot(nowNs: capture).sourceGaps, 0)
        next(after: 16)  // 1.6 periods: one frame was missing
        XCTAssertEqual(t.snapshot(nowNs: capture).sourceGaps, 1)
        next(after: 30)  // 3 periods: a second gap; the total is 2
        XCTAssertEqual(t.snapshot(nowNs: capture).sourceGaps, 2)
        next(after: 10)
        XCTAssertEqual(t.snapshot(nowNs: capture).sourceGaps, 2, "a total, steady frames add nothing")
    }

    func testSourceGapIgnoresArrivalAndRestart() {
        var t = StatsTracker(startNs: 0, maxFps: 60)
        // Captured steadily, arrived in a bunch: no source gap.
        for i in 0..<10 { t.frameShown(frame(UInt32(i), capture: 5 * sec + UInt64(i) * period), arrivalNs: 6 * sec + UInt64(i) * ms) }
        XCTAssertEqual(t.snapshot(nowNs: 7 * sec).sourceGaps, 0)
        // A new game: its capture times are not compared with the old one's.
        t.videoRestarted()
        t.frameShown(frame(0, capture: 90 * sec), arrivalNs: 8 * sec)
        XCTAssertEqual(t.snapshot(nowNs: 8 * sec).sourceGaps, 0)
    }

    func testSourceGapPeriodFollowsTheSessionsFrameRate() {
        var t = StatsTracker(startNs: 0, maxFps: 30)
        t.frameShown(frame(0, capture: 5 * sec), arrivalNs: 5 * sec)
        t.frameShown(frame(1, capture: 5 * sec + 1_000_000_000 / 30 * 14 / 10), arrivalNs: 5 * sec)  // 1.4 periods of 30 fps
        XCTAssertEqual(t.snapshot(nowNs: 6 * sec).sourceGaps, 0)
        t.frameShown(frame(2, capture: 5 * sec + 1_000_000_000 / 30 * 30 / 10), arrivalNs: 5 * sec)  // 1.6 periods after the last
        XCTAssertEqual(t.snapshot(nowNs: 6 * sec).sourceGaps, 1)
    }

    func testSourceFpsIsByCaptureTime() {
        var t = StatsTracker(startNs: 0, maxFps: 60)
        // 3 s at 30 captured frames a second, all arriving in the last instant: the network is not the source's rate.
        for i in 0..<90 { t.frameShown(frame(UInt32(i), capture: 10 * sec + UInt64(i) * sec / 30), arrivalNs: 20 * sec + UInt64(i) * ms) }
        XCTAssertEqual(t.snapshot(nowNs: 20 * sec + 100 * ms).sourceFps, 30, accuracy: 1)
        // The first half second of a stream is right too.
        var u = StatsTracker(startNs: 0, maxFps: 60)
        for i in 0..<30 { u.frameShown(frame(UInt32(i), capture: 10 * sec + UInt64(i) * sec / 60), arrivalNs: 20 * sec + UInt64(i) * ms) }
        XCTAssertEqual(u.snapshot(nowNs: 20 * sec + 50 * ms).sourceFps, 60, accuracy: 3)
    }

    func testCaptureTimesThatGoBackwardsOrRepeatDoNotTrap() {
        var t = StatsTracker(startNs: 0, maxFps: 60)
        let caps: [UInt64] = [10 * sec, 10 * sec, 10 * sec + period, 5 * sec, 5 * sec, 3 * sec, 10 * sec + 2 * period, UInt64.max, 0]
        for (i, c) in caps.enumerated() { t.frameShown(frame(UInt32(i), capture: c), arrivalNs: 20 * sec + UInt64(i) * ms) }
        let s = t.snapshot(nowNs: 21 * sec)
        XCTAssertTrue(s.sourceFps.isFinite)
        XCTAssertGreaterThanOrEqual(s.sourceFps, 0)
        // Only forward steps count; a repeat or a step back is no gap.
        var u = StatsTracker(startNs: 0, maxFps: 60)
        for (i, c) in [10 * sec, 10 * sec, 9 * sec, 9 * sec + period].enumerated() {
            u.frameShown(frame(UInt32(i), capture: c), arrivalNs: 20 * sec)
        }
        XCTAssertEqual(u.snapshot(nowNs: 21 * sec).sourceGaps, 0)
        // Extreme values on the delay path too.
        var v = StatsTracker(startNs: 0)
        pong(&v, send: 1 * sec, rtt: 2 * ms, offset: 0)
        v.frameShown(frame(0, capture: UInt64.max), arrivalNs: 2 * sec)
        v.displayed(captureNs: UInt64.max, nowNs: 3 * sec)
        _ = v.snapshot(nowNs: 4 * sec)
    }

    func testRestartClearsTheRateWindows() {
        var t = StatsTracker(startNs: 0)
        for i in 0..<60 { t.frameShown(sized(UInt32(i), bytes: 50_000), arrivalNs: 10 * sec + UInt64(i) * sec / 60) }
        t.videoRestarted()
        // 0.1 s later the new stream's first frames: the old stream's must not be counted over the short new span.
        for i in 0..<6 { t.frameShown(sized(UInt32(i), bytes: 1_000), arrivalNs: 11 * sec + 100 * ms + UInt64(i) * sec / 60) }
        let s = t.snapshot(nowNs: 11 * sec + 200 * ms)
        XCTAssertEqual(s.fps, 12, accuracy: 1)  // 6 frames over the 0.5 s minimum span
        XCTAssertEqual(s.bitrateMbps, 0.096, accuracy: 0.01)
    }

    /// The tool's last line carries one number for each thing a person judges a run by.
    func testTheRunLineCarriesTheRunsNumbers() {
        var st = SessionStats()
        st.framesShown = 600; st.fps = 59.5; st.p95DelayMs = 12.25; st.framesSkipped = 3; st.audioLost = 1
        st.framesGivenUp = 4; st.fragmentsAsked = 20; st.fragmentsRecovered = 17; st.repairRequests = 6; st.refreshes = 2
        st.escalations = 1; st.keys = 1; st.decodeErrors = 0; st.acksSent = 150
        st.rateBps = 30_000_000; st.rateCeilingBps = 50_000_000; st.rateCuts = 2
        st.rateStartBps = 25_000_000; st.rateLowBps = 17_500_000
        st.rateChanges = [RateChange(seq: 1, atSeconds: 0, fromBps: 25_000_000, toBps: 25_000_000, why: .start),
                          RateChange(seq: 2, atSeconds: 3, fromBps: 25_000_000, toBps: 17_500_000, why: .loss),
                          RateChange(seq: 3, atSeconds: 9, fromBps: 17_500_000, toBps: 30_000_000, why: .climb)]
        XCTAssertEqual(st.runLine(longestGapMs: 83.4),
                       "frames=600 fps=59.5 p95_ms=12.2 skipped=3 audio_lost=1 given_up=4 asked=20 recovered=17 repairs=6 "
                       + "repair_frames=2 escalations=1 keys=1 decode_errors=0 acks=150 max_gap_ms=83 rate_mbps=25.0/17.5/30.0 cuts=2")
    }

    /// After `--quit` the last 2 s hold no pictures (`fps` 0.0): the line takes the tool's rate over the run instead.
    func testTheRunLineTakesTheRateOverTheRunWhenTheToolGivesOne() {
        var st = SessionStats()
        st.framesShown = 600; st.fps = 0
        XCTAssertTrue(st.runLine(longestGapMs: 0).contains("frames=600 fps=0.0 "), st.runLine(longestGapMs: 0))
        XCTAssertTrue(st.runLine(longestGapMs: 0, runFps: 59.84).contains("frames=600 fps=59.8 "), st.runLine(longestGapMs: 0, runFps: 59.84))
    }

    /// No rate change in a run: the rate in force is start, low and end (the Host's when the session's own is fixed),
    /// never zeros.
    func testTheRunLineShowsTheRateInForceWhenNothingChanged() {
        var st = SessionStats()
        st.rateBps = 25_000_000
        XCTAssertTrue(st.runLine(longestGapMs: 0).contains("rate_mbps=25.0/25.0/25.0 cuts=0"), st.runLine(longestGapMs: 0))
        var fixed = SessionStats()
        fixed.host = HostStats(framesFromGame: 1, framesSent: 1, framesDropped: 0, resent: 0, rateBps: 40_000_000)
        XCTAssertTrue(fixed.runLine(longestGapMs: 0).contains("rate_mbps=40.0/40.0/40.0 cuts=0"), fixed.runLine(longestGapMs: 0))
    }

    /// The start and the low do not roll with the log of the newest 32 changes.
    func testTheRunLineKeepsTheTrueStartAndLowPast32Changes() async {
        let s = ClientSession(identity: Identity(), name: "Test Client", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 5)
        // The first is the start (25), the second the run's low (3), then 38 more between 10 and 29.
        var rates: [UInt32] = [25, 3]
        rates += (0..<38).map { UInt32(10 + $0 % 20) }
        var from: UInt32 = 0
        for r in rates {
            await s.logRate(0, from: from, to: r * 1_000_000, why: .climb, delivered: 0, produced: 0, floorNs: nil)
            from = r * 1_000_000
        }
        var st = await s.stats()
        XCTAssertEqual(st.rateChanges.count, 32)
        XCTAssertGreaterThan(st.rateChanges.first?.toBps ?? 0, 3_000_000, "the log has rolled past the low")
        st.rateBps = from
        let line = st.runLine(longestGapMs: 0)
        XCTAssertTrue(line.contains("rate_mbps=25.0/3.0/\(String(format: "%.1f", Double(from) / 1e6))"), line)
        await s.close()
    }

    /// The rule for a decoded frame, a refused one: the session hears `frameDecoded` or `decodeFailed`, nothing else.
    func testTheDecodeReportStepTellsTheSessionTheResult() async {
        let s = ClientSession(identity: Identity(), name: "Test Client", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 5)
        let key = AssembledFrame(frame: 1, key: true, captureNs: 1, width: 16, height: 16, data: Data([1]))
        let bad = AssembledFrame(frame: 2, key: false, captureNs: 2, width: 16, height: 16, data: Data([2]))
        var shown = 0
        for f in [key, bad] {
            await DecodeReport.step(f, decode: { $0.key ? "picture" : nil }, picture: { _ in shown += 1 },
                                    decoded: { await s.frameDecoded($0) }, failed: { await s.decodeFailed($0) })
        }
        let st = await s.stats()
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(st.acksSent, 1, "the key frame was acknowledged")
        XCTAssertEqual(st.decodeErrors, 1, "the refused frame was reported")
        await s.close()
    }

    /// The second's largest gap between video datagrams and largest round trip are taken and reset.
    func testSecondMaximaAreTakenAndReset() {
        var t = StatsTracker(startNs: 0)
        XCTAssertEqual(t.takeMaxima(), SecondMaxima(), "no sample, no value")
        for ms in [0, 16, 32, 137, 153] { t.videoDatagram(nowNs: UInt64(ms) * 1_000_000) }
        t.pong(sendNs: 0, receiveNs: 9_000_000, hostNs: 0)
        t.pong(sendNs: 100_000_000, receiveNs: 148_000_000, hostNs: 0)
        t.pong(sendNs: 200_000_000, receiveNs: 205_000_000, hostNs: 0)
        let a = t.takeMaxima()
        XCTAssertEqual(a.netGapMaxMs ?? 0, 105, accuracy: 0.001)
        XCTAssertEqual(a.rttMaxMs ?? 0, 48, accuracy: 0.001)
        _ = t.snapshot(nowNs: 300_000_000)
        t.videoDatagram(nowNs: 170_000_000)
        XCTAssertEqual(t.takeMaxima().netGapMaxMs ?? 0, 17, accuracy: 0.001, "the interval across a take is kept; a snapshot resets nothing")
        XCTAssertEqual(t.takeMaxima(), SecondMaxima())
    }
}
