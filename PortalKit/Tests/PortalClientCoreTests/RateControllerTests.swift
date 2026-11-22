import XCTest
import PortalKit
@testable import PortalClientCore

/// The rate rules with synthetic samples, one every 200 ms unless said -> .claude/client.md § rate
final class RateControllerTests: XCTestCase {
    private let ms: UInt64 = 1_000_000, sec: UInt64 = 1_000_000_000
    private let origin: UInt64 = 1_000_000_000_000
    private let mbit = 1_000_000.0

    /// A clean sample at `t`: 1,000 fragments, 12 frames, nothing asked, the encoder producing and the link delivering
    /// the rate (or `delivered`), the ping floor at `floorMs` (8 ms).
    private func clean(_ c: RateController, _ t: UInt64, floorMs: Double? = 8, delivered: Double? = nil) -> RateSample {
        RateSample(nowNs: t, fragmentsReceived: 1000, framesCompleted: 12, deliveredBps: delivered ?? Double(c.rateBps),
                   producedBps: Double(c.rateBps), producedRecentBps: Double(c.rateBps), rttFloorNs: floorMs.map { UInt64($0 * 1e6) })
    }

    /// Feeds clean samples every 200 ms from `from` (exclusive) to `to` (inclusive); every change with its time.
    @discardableResult
    private func run(_ c: inout RateController, from: UInt64, to: UInt64, floorMs: Double? = 8) -> [(at: UInt64, bps: UInt32)] {
        var changes: [(at: UInt64, bps: UInt32)] = []
        var t = from + RateController.samplePeriodNs
        while t <= to {
            if let r = c.update(clean(c, t, floorMs: floorMs)) { changes.append((t, r)) }
            t += RateController.samplePeriodNs
        }
        return changes
    }

    /// Clean samples until the rate has reached the ceiling and run clean there for a second with demand; the time it ends.
    private func atCeiling(_ c: inout RateController) -> UInt64 {
        _ = c.update(clean(c, origin))
        run(&c, from: origin, to: origin + 6 * sec)
        XCTAssertEqual(c.rateBps, c.ceilingBps)
        return origin + 6 * sec
    }

    /// Two frames given up in the sample, the encoder producing the rate.
    private func trouble(_ c: inout RateController, _ t: UInt64, delivered: Double? = nil) -> UInt32? {
        c.update(RateSample(nowNs: t, framesGivenUp: 2, fragmentsReceived: 1000, framesCompleted: 10,
                            deliveredBps: delivered ?? Double(c.rateBps), producedBps: Double(c.rateBps),
                            producedRecentBps: Double(c.rateBps), rttFloorNs: 8_000_000))
    }

    func testTheStartIsHalfTheCeilingNotUnderTenMbit() {
        XCTAssertEqual(RateController(ceilingBps: 100_000_000).rateBps, 50_000_000)
        XCTAssertEqual(RateController(ceilingBps: 30_000_000).rateBps, 15_000_000)
        XCTAssertEqual(RateController(ceilingBps: 16_000_000).rateBps, 10_000_000)
        XCTAssertEqual(RateController(ceilingBps: 8_000_000).rateBps, 8_000_000)
    }

    /// From 50 to a 100 Mbit/s ceiling in about 4 clean seconds, never more than + 25 % a step, one step a second at most.
    func testAGoodLinkReachesTheCeilingFast() {
        var c = RateController(ceilingBps: 100_000_000)
        let changes = run(&c, from: origin, to: origin + 6 * sec)
        XCTAssertEqual(c.rateBps, 100_000_000, "\(changes)")
        let reached = changes.first { $0.bps == 100_000_000 }.map { Double($0.at - origin) / 1e9 } ?? .infinity
        XCTAssertLessThanOrEqual(reached, 4.4, "the ceiling at \(reached) s")
        var previous = 50_000_000.0, previousAt = origin
        for ch in changes {
            XCTAssertLessThanOrEqual(Double(ch.bps), previous * 1.25 + 1, "a step of more than 25 %")
            XCTAssertGreaterThanOrEqual(ch.at - previousAt, sec, "two steps within a second")
            previous = Double(ch.bps); previousAt = ch.at
        }
        XCTAssertEqual(c.cuts, 0)
    }

    /// A quiet picture (the encoder producing under half the rate) on a clean link: no climb; once it is busy, the climb.
    func testAQuietPictureDoesNotRaiseTheRate() {
        var c = RateController(ceilingBps: 100_000_000)
        var t = origin
        for _ in 0..<20 {
            t += RateController.samplePeriodNs
            XCTAssertNil(c.update(RateSample(nowNs: t, fragmentsReceived: 30, framesCompleted: 12, deliveredBps: 0.1e6,
                                             producedBps: 0.1e6, producedRecentBps: 0.1e6, rttFloorNs: 2_000_000)))
        }
        XCTAssertEqual(c.rateBps, 50_000_000)
        XCTAssertEqual(c.update(clean(c, t + RateController.samplePeriodNs)), 62_500_000, "busy after 4 clean seconds: at once")
        XCTAssertEqual(c.reason, .climb)
    }

    /// Frames given up: one cut to 0.7 x, then nothing for 5 s however clean; then the climb.
    func testOneTroubleSampleCutsOnceAndHolds() {
        var c = RateController(ceilingBps: 100_000_000)
        let t0 = atCeiling(&c) + 200 * ms
        XCTAssertEqual(trouble(&c, t0), 70_000_000)
        XCTAssertEqual(c.cuts, 1)
        let held = run(&c, from: t0, to: t0 + 5 * sec - ms)
        XCTAssertTrue(held.isEmpty, "a change within 5 s of the cut: \(held)")
        let after = run(&c, from: t0 + 5 * sec - ms, to: t0 + 7 * sec)
        XCTAssertFalse(after.isEmpty, "no increase after 5 clean seconds")
        XCTAssertEqual(c.cuts, 1)
    }

    /// Trouble in every sample: one cut each time the last one could have shown (never sooner), down to the floor.
    func testSustainedTroubleWalksDownToTheFloor() {
        var c = RateController(ceilingBps: 100_000_000)
        var cuts: [UInt64] = []
        var t = origin
        for _ in 0..<100 {
            t += RateController.samplePeriodNs
            if trouble(&c, t, delivered: Double(c.rateBps)) != nil { cuts.append(t) }
        }
        XCTAssertEqual(c.rateBps, RateController.floorBps)
        XCTAssertGreaterThanOrEqual(cuts.count, 9, "50 -> 2 Mbit/s at 0.7 a step takes 9 cuts")
        // A cut right after an increase waits for the Host's 250 ms between configs too.
        var e = RateController(ceilingBps: 100_000_000)
        run(&e, from: origin, to: origin + 1200 * ms)
        XCTAssertEqual(e.rateBps, 62_500_000, "the increase at 1.2 s")
        XCTAssertNotNil(trouble(&e, origin + 1400 * ms))
        XCTAssertNil(trouble(&e, origin + 1800 * ms), "the Host applied the cut 250 ms after the increase: 400 ms from then")
        XCTAssertNotNil(trouble(&e, origin + 2200 * ms))
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 400 * ms, "cuts \(Double(b - a) / 1e6) ms apart: the last had not shown")
            XCTAssertLessThanOrEqual(b - a, 600 * ms, "cuts \(Double(b - a) / 1e6) ms apart: too slow")
        }
        XCTAssertNil(trouble(&c, t + 2 * sec), "a cut below the floor")
    }

    /// Trouble at 50 Mbit/s with 12 delivered: about 10 (0.85 x delivered) in one step.
    func testACutGoesBelowWhatTheLinkDelivered() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        let r = trouble(&c, origin + 200 * ms, delivered: 12_000_000)
        XCTAssertEqual(r, 10_200_000)
        XCTAssertEqual(c.cuts, 1)
    }

    /// Trouble at 100 (-> 70), a clean second, and trouble again at 70 (-> 49): a new episode, the memory is 70. After 5 s back to 63
    /// (90 %) within about 5 clean seconds; held there until 30 clean seconds; then + 5 % every 5 s; once 60 clean
    /// seconds above the remembered 70, the fast climb again.
    func testTheClimbBackHoldsBelowTheTroubleRateProbesAndFades() {
        var c = RateController(ceilingBps: 200_000_000)
        XCTAssertEqual(c.rateBps, 100_000_000)
        _ = c.update(clean(c, origin))
        XCTAssertEqual(trouble(&c, origin + 200 * ms), 70_000_000)
        XCTAssertEqual(c.memoryBps, 100_000_000, "the start never ran clean, no link evidence: the rate the episode began at")
        run(&c, from: origin + 200 * ms, to: origin + 1400 * ms)  // a clean second: the next trouble is a new episode
        let t0 = origin + 1600 * ms
        XCTAssertEqual(trouble(&c, t0), 49_000_000)
        XCTAssertEqual(c.memoryBps, 70_000_000)
        var changes = run(&c, from: t0, to: t0 + 11 * sec)
        XCTAssertEqual(c.rateBps, 63_000_000, "\(changes)")
        let back = changes.first { $0.bps == 63_000_000 }.map { Double($0.at - t0) / 1e9 } ?? .infinity
        XCTAssertLessThanOrEqual(back, 10.5, "90 % of the trouble rate \(back) s after the cut")
        XCTAssertTrue(changes.allSatisfy { $0.at >= t0 + 5 * sec })
        changes = run(&c, from: t0 + 11 * sec, to: t0 + 30 * sec - 300 * ms)
        XCTAssertTrue(changes.isEmpty, "a probe before 30 clean seconds: \(changes)")
        changes = run(&c, from: t0 + 30 * sec - 300 * ms, to: t0 + 31 * sec)
        XCTAssertEqual(changes.map(\.bps), [66_150_000], "the first probe")
        changes = run(&c, from: t0 + 31 * sec, to: t0 + 50 * sec)
        for (a, b) in zip([(t0 + 30 * sec, UInt32(66_150_000))] + changes.map { ($0.at, $0.bps) }, changes) {
            XCTAssertGreaterThanOrEqual(b.at - a.0, 5 * sec - 300 * ms, "probes closer than 5 s")
            XCTAssertLessThanOrEqual(Double(b.bps), Double(a.1) * 1.05 + 1, "a probe step over 5 %")
        }
        XCTAssertGreaterThan(c.rateBps, 70_000_000, "the probes never passed the remembered rate")
        XCTAssertNotNil(c.memoryBps)
        // 60 clean seconds above the memory: it fades and the climb is fast again.
        changes = run(&c, from: t0 + 50 * sec, to: t0 + 115 * sec)
        XCTAssertNil(c.memoryBps, "the memory did not fade")
        let fast = zip(changes, changes.dropFirst()).contains { Double($0.1.bps) > Double($0.0.bps) * 1.2 }
        XCTAssertTrue(fast, "no fast step after the fade: \(changes.map(\.bps))")
    }

    /// Climbs from the start through a trouble with 40 delivered (cut 34, memory 40) until the probes pass the memory;
    /// the time of the last sample. The controller's rate is above 40 then, its last probe 0 s old.
    private func probeAboveMemory(_ c: inout RateController) -> UInt64 {
        _ = c.update(clean(c, origin))
        let t0 = origin + 200 * ms
        XCTAssertEqual(trouble(&c, t0, delivered: 40_000_000), 34_000_000)
        XCTAssertEqual(c.memoryBps, 40_000_000, "the link's 40")
        var t = t0
        while c.rateBps <= 40_000_000 && t < t0 + 60 * sec {
            t += RateController.samplePeriodNs
            _ = c.update(clean(c, t))
        }
        XCTAssertGreaterThan(c.rateBps, 40_000_000, "the probes did not pass the memory")
        XCTAssertEqual(c.reason, .probe)
        return t
    }

    /// Trouble at a probe above the memory that never ran clean (under a second) is not a rate that ran clean: the cut is
    /// 0.7 x, the memory stays where it was.
    func testTroubleAtAnUnprovenProbeLeavesTheMemoryWhereItWas() {
        var c = RateController(ceilingBps: 200_000_000)
        var t = probeAboveMemory(&c)
        let probe = c.rateBps
        t += RateController.samplePeriodNs
        XCTAssertEqual(trouble(&c, t), UInt32((Double(probe) * 0.7).rounded()))
        XCTAssertEqual(c.memoryBps, 40_000_000, "an unproven probe raised the memory")
    }

    /// Trouble at an unproven probe above the memory, with the link delivering less than the memory: the memory falls to
    /// what the link delivered, and the climb back aims at 0.9 x that, not at 0.9 x the old memory.
    func testLinkEvidenceAtAnUnprovenProbeLowersTheMemoryAndTheReturnClimbAimsAtIt() {
        var c = RateController(ceilingBps: 200_000_000)
        var t = probeAboveMemory(&c)
        t += RateController.samplePeriodNs
        let cut = trouble(&c, t, delivered: 30_000_000)
        XCTAssertEqual(c.memoryBps, 30_000_000, "the link delivered 30; the memory stayed at 40")
        XCTAssertNotNil(cut)
        XCTAssertLessThan(Double(cut ?? .max), 0.85 * 30_000_000 + 1, "the cut is under what the link delivered")
        var top = c.rateBps
        for _ in 0..<(12 * 5) {  // 12 clean seconds, demand present
            t += RateController.samplePeriodNs
            _ = c.update(clean(c, t))
            top = max(top, c.rateBps)
        }
        XCTAssertEqual(top, 27_000_000, "the return climb aims at 0.9 x the lowered memory (36 M if the memory stayed)")
        XCTAssertEqual(c.rateBps, 27_000_000)
    }

    /// A probe that ran clean for more than a second is proven: trouble after that makes its rate the memory.
    func testTroubleAtAProvenProbeMakesItTheMemory() {
        var c = RateController(ceilingBps: 200_000_000)
        var t = probeAboveMemory(&c)
        let probe = c.rateBps
        for _ in 0..<7 {  // 1.4 s clean at the probe's rate, demand present
            t += RateController.samplePeriodNs
            _ = c.update(clean(c, t))
        }
        XCTAssertEqual(c.rateBps, probe, "the next probe came too soon for the test")
        t += RateController.samplePeriodNs
        _ = trouble(&c, t)
        XCTAssertEqual(c.memoryBps, probe, "a probe that ran clean is the memory")
    }

    /// A ping floor that is high but steady is the path, not a queue: no cut. A rise over the 30 s minimum is, and cuts
    /// 0.7 x (not to what was delivered).
    func testAConstantHighRoundTripIsIgnoredAndARiseIsNot() {
        var c = RateController(ceilingBps: 100_000_000)
        run(&c, from: origin, to: origin + 6 * sec, floorMs: 80)
        XCTAssertEqual(c.rateBps, 100_000_000)
        XCTAssertEqual(c.cuts, 0)
        var d = RateController(ceilingBps: 100_000_000)
        run(&d, from: origin, to: origin + 2200 * ms, floorMs: 8)  // the last increase at 2.2 s: none for a second now
        XCTAssertEqual(d.rateBps, 78_125_000)
        XCTAssertNil(d.update(clean(d, origin + 2400 * ms, floorMs: 22)), "+ 14 ms is under the 16 ms rule (2 x 8)")
        XCTAssertEqual(d.update(clean(d, origin + 2600 * ms, floorMs: 30, delivered: 20e6)), 54_687_500,
                       "+ 22 ms over the minimum is a queue: 0.7 x")
        XCTAssertEqual(d.reason, .queue)
        XCTAssertEqual(d.rttMinNs, 8_000_000)
    }

    /// Pings every 100 ms (round trip 3 ms) into a tracker, the controller fed its floor every 200 ms; `pause`: from 2 s,
    /// no pong arrives for that long, then the ones sent meanwhile arrive together (each round trip its wait); `rise`:
    /// from 2 s every round trip is 40 ms more, on cadence. The time of the first cut, or nil. (The pause runs to the
    /// first x.x60 s at or after its length.)
    private func pongs(pause: UInt64 = 0, rise: UInt64 = 0, until end: UInt64 = 8_000_000_000) -> (cut: UInt64?, c: RateController) {
        var tracker = StatsTracker(startNs: 0)
        var c = RateController(ceilingBps: 100_000_000)
        var events: [(arrive: UInt64, send: UInt64)] = []
        // The pause ends 40 ms before a sample, with no ping between: that sample sees only the burst.
        var resume = origin + 2 * sec + pause
        resume += (160 * ms + 200 * ms - (resume - origin) % (200 * ms)) % (200 * ms)
        var send = origin
        while send < origin + end {
            var arrive = send + 3 * ms
            if send >= origin + 2 * sec {
                if pause > 0, send < resume { arrive = resume + 1 * ms }
                arrive += rise
            }
            events.append((arrive, send))
            send += 100 * ms
        }
        events.sort { $0.arrive < $1.arrive }
        var next = 0, cut: UInt64?
        var t = origin + RateController.samplePeriodNs
        while t <= origin + end {
            while next < events.count, events[next].arrive <= t {
                tracker.pong(sendNs: events[next].send, receiveNs: events[next].arrive, hostNs: events[next].send)
                next += 1
            }
            var s = clean(c, t)
            s.rttFloorNs = tracker.rttFloorNs(nowNs: t)
            if let r = c.update(s), r < UInt32(100_000_000), cut == nil, c.cuts > 0 { cut = t }
            t += RateController.samplePeriodNs
        }
        return (cut, c)
    }

    /// The pongs held by a radio pause arrive in a burst, each round trip carrying its wait: no queue, no cut.
    func testLatePongsAfterAPauseAreNotAQueue() {
        for pause in [300 * ms, 600 * ms, 2 * sec] {
            let r = pongs(pause: pause)
            XCTAssertEqual(r.c.cuts, 0, "a \(pause / ms) ms pause cut at \(r.cut.map { Double($0 - origin) / 1e9 } ?? 0) s")
        }
    }

    /// Every pong 40 ms later, on cadence (a queue): trouble at the first sample whose 300 ms window holds only late pongs
    /// (the last on-time pong arrived at 1.903 s: by 2.203 s, seen at the next 200 ms sample).
    func testASteadyRiseOnEveryPongIsAQueueWithin300ms() throws {
        let r = pongs(rise: 40 * ms)
        let cut = try XCTUnwrap(r.cut, "a 40 ms queue was not seen")
        XCTAssertLessThanOrEqual(cut, origin + 1903 * ms + 300 * ms + RateController.samplePeriodNs, "seen \(Double(cut - origin) / 1e9) s")
        XCTAssertEqual(r.c.reason, .queue)
    }

    /// No ping floor (under 2 pongs in its 300 ms) is no queue evidence, and the frame delay is no signal at all.
    func testNoPingFloorIsNoQueueEvidence() {
        var c = RateController(ceilingBps: 100_000_000)
        run(&c, from: origin, to: origin + 2 * sec)
        let r = c.update(RateSample(nowNs: origin + 2 * sec + 200 * ms, fragmentsReceived: 1000, framesCompleted: 12,
                                    deliveredBps: 30e6, rttFloorNs: nil))
        XCTAssertEqual(c.cuts, 0, "no floor cut the rate to \(String(describing: r))")
    }

    /// Queue trouble with the encoder producing far under the rate (a quiet picture): 0.7 x the rate, not 0.85 x what
    /// was delivered; and never under 0.7 x what was produced in the last second.
    func testAQueueCutIsSevenTenthsOfTheRateAtMostDownToSevenTenthsOfWhatWasProduced() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        let quiet = RateSample(nowNs: origin + 200 * ms, fragmentsReceived: 40, framesCompleted: 12, deliveredBps: 1e6,
                               producedBps: 1e6, producedRecentBps: 1e6, rttFloorNs: 40_000_000)
        XCTAssertEqual(c.update(quiet), 35_000_000)
        XCTAssertEqual(c.reason, .queue)
        var d = RateController(ceilingBps: 100_000_000)
        _ = d.update(clean(d, origin))
        var over = quiet
        over.producedBps = 60e6; over.producedRecentBps = 60e6; over.deliveredBps = 60e6
        XCTAssertEqual(d.update(over), 42_000_000, "0.7 x the 60 Mbit/s produced, above 0.7 x the rate")
        // 0.7 x produced at or above the rate: the cut is 0.7 x the rate, never no change.
        var e = RateController(ceilingBps: 100_000_000)
        _ = e.update(clean(e, origin))
        var high = quiet
        high.producedBps = 80e6; high.producedRecentBps = 80e6; high.deliveredBps = 80e6
        let cut = e.update(high)
        XCTAssertEqual(cut, 35_000_000)
        XCTAssertLessThan(cut ?? .max, 50_000_000, "a cut that does not cut")
    }

    /// A quiet picture on a good link (0.5 Mbit/s produced and delivered) with two frames given up: 0.7 x the rate, the
    /// memory the rate; inside the hold the little delivered since the cut is no measured cut either.
    func testAQuietPictureDoesNotPoisonTheCutTheMemoryOrTheMeasuredCut() {
        func quiet(_ t: UInt64, givenUp: Int, bytes: Int = 12_500) -> RateSample {
            RateSample(nowNs: t, framesGivenUp: givenUp, fragmentsReceived: 20, framesCompleted: 10, deliveredBps: 0.5e6,
                       producedBps: 0.5e6, producedRecentBps: 0.5e6, bytesReceived: bytes, rttFloorNs: 8_000_000)
        }
        var c = RateController(ceilingBps: 80_000_000)
        _ = c.update(clean(c, origin))
        XCTAssertEqual(c.update(quiet(origin + 200 * ms, givenUp: 2)), 28_000_000)
        XCTAssertEqual(c.memoryBps, 40_000_000, "a quiet picture shows no link: the rate the episode began at")
        XCTAssertEqual(c.reason, .givenUp)
        XCTAssertNil(c.update(quiet(origin + 400 * ms, givenUp: 2)), "a measured cut from a quiet picture")
        XCTAssertEqual(c.rateBps, 28_000_000)
        // A picture that just got busy: the delivered window is mostly the quiet one (5 of 100 Mbit/s produced in it).
        var d = RateController(ceilingBps: 100_000_000)
        _ = d.update(clean(d, origin))
        XCTAssertEqual(d.update(RateSample(nowNs: origin + 200 * ms, fragmentsAsked: 300, fragmentsReceived: 400, framesCompleted: 3,
                                           deliveredBps: 4e6, producedBps: 2e6, producedRecentBps: 5e6, rttFloorNs: 8_000_000)),
                       35_000_000, "a cut from a window the busy picture had hardly begun")
    }

    /// Repaired loss is not trouble: 1 % asked again (`lossy`), 2.3 % in runs (`bursty`: 0.3 % of datagrams start a run
    /// of 3...12), even a sample with 8 % in it; loss well beyond what repair handles (over 10 % of the last second) is.
    func testTheShareAskedAgainCountsOverTheLastSecond() {
        var c = RateController(ceilingBps: 100_000_000)
        var t = origin
        for asked in [10, 10, 10, 23, 23, 80, 23, 23, 10, 10] {
            t += RateController.samplePeriodNs
            _ = c.update(RateSample(nowNs: t, fragmentsAsked: asked, fragmentsReceived: 1000, framesCompleted: 12, deliveredBps: 50e6))
        }
        XCTAssertEqual(c.cuts, 0, "repaired loss cut the rate")
        t += RateController.samplePeriodNs
        XCTAssertNotNil(c.update(RateSample(nowNs: t, fragmentsAsked: 600, fragmentsReceived: 1000, framesCompleted: 12, deliveredBps: 50e6)))
    }

    /// A refresh sample 50 ms after a regular one with nothing in it is short, not a stall: the clean second still counts.
    func testAShortEmptySampleDoesNotRestartTheCleanSecond() {
        var c = RateController(ceilingBps: 100_000_000)
        run(&c, from: origin, to: origin + 800 * ms)
        XCTAssertNil(c.update(RateSample(nowNs: origin + 850 * ms, fragmentsReceived: 0, deliveredBps: 50e6)))
        XCTAssertEqual(c.update(clean(c, origin + 1200 * ms)), 62_500_000)
    }

    /// The cancel rule, assembler to controller: two frames given up whose missing fragments arrive 40 ms later (a
    /// delayed burst) are no trouble; the same two with nothing late are, 150 ms after the give-up.
    func testGiveUpsCancelledByLateFragmentsAreNoTrouble() {
        func run(late: Bool) -> RateController {
            var a = FrameAssembler()
            func frags(_ n: UInt32, key: Bool) -> [VideoFragment] {
                FrameSplitter.split(frame: n, key: key, captureNs: 0, width: 1280, height: 720,
                                    data: Data(repeating: UInt8(n), count: 4 * Wire.maxVideoPayload))
            }
            let t0 = origin
            for f in frags(1, key: true) { _ = a.push(f, nowNs: t0) }
            let f2 = frags(2, key: false), f3 = frags(3, key: false)
            for f in [f2[0], f2[2], f2[3], f3[0], f3[2], f3[3]] { _ = a.push(f, nowNs: t0 + 17 * ms) }
            for k in 18...80 { _ = a.tick(nowNs: t0 + UInt64(k) * ms, rttNs: 2 * ms) }
            XCTAssertEqual(a.counts.framesGivenUp, 2)
            if late { _ = a.push(f2[1], nowNs: t0 + 90 * ms); _ = a.push(f3[1], nowNs: t0 + 91 * ms) }
            var c = RateController(ceilingBps: 100_000_000)
            _ = c.update(clean(c, t0))
            for k in 1...5 {
                let t = t0 + UInt64(k) * RateController.samplePeriodNs
                var s = clean(c, t)
                s.framesGivenUp = a.settledGiveUps(nowNs: t)
                _ = c.update(s)
            }
            return c
        }
        XCTAssertEqual(run(late: true).cuts, 0, "a delayed burst cut the rate")
        XCTAssertEqual(run(late: false).cuts, 1, "two frames lost for good")
    }

    /// One frame given up (a loss run that took the asks too) is not a shortage; two within a second are.
    func testOneFrameGivenUpIsNotTroubleTwoInASecondAre() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        let one = RateSample(nowNs: origin + 200 * ms, framesGivenUp: 1, fragmentsReceived: 1000, framesCompleted: 12, deliveredBps: 50e6)
        XCTAssertNil(c.update(one))
        run(&c, from: origin + 200 * ms, to: origin + 2 * sec)
        XCTAssertEqual(c.cuts, 0)
        let rate = c.rateBps
        var again = one
        again.deliveredBps = Double(rate)
        again.nowNs = origin + 2200 * ms
        XCTAssertNil(c.update(again))
        again.nowNs = origin + 2600 * ms
        XCTAssertEqual(c.update(again), UInt32((0.7 * Double(rate)).rounded()), "two frames given up in 0.4 s")
    }

    /// The first cut is sized from a window from before the shortage showed (40 -> 28 while 6 Mbit/s get through):
    /// 200 ms or more after it, trouble with under half the rate delivered since the cut cuts to 0.85 x that, inside
    /// the hold; trouble with more delivered waits for the hold.
    func testAMeasuredCutFollowsAFirstCutThatWasTooSmall() {
        func sample(_ t: UInt64, bytes: Int) -> RateSample {
            RateSample(nowNs: t, framesGivenUp: 2, fragmentsReceived: 200, framesCompleted: 4, deliveredBps: 38e6,
                       producedBps: 40e6, producedRecentBps: 28e6, bytesReceived: bytes)
        }
        let sixMbitFor200ms = 150_000  // 6 Mbit/s for 200 ms, in bytes
        var c = RateController(ceilingBps: 80_000_000)
        XCTAssertEqual(c.rateBps, 40_000_000)
        _ = c.update(clean(c, origin))
        XCTAssertEqual(c.update(sample(origin + 200 * ms, bytes: 1_000_000)), 28_000_000)
        XCTAssertNil(c.update(sample(origin + 300 * ms, bytes: sixMbitFor200ms / 2)), "a measured cut 100 ms after the first")
        XCTAssertEqual(c.update(sample(origin + 400 * ms, bytes: sixMbitFor200ms / 2)), 5_100_000)
        XCTAssertEqual(c.memoryBps, 40_000_000, "the measured cut is the same episode (no link shown: the rate it began at)")
        XCTAssertNil(c.update(sample(origin + 500 * ms, bytes: 1000)), "a second measured cut 100 ms after the first")
        var d = RateController(ceilingBps: 80_000_000)
        _ = d.update(clean(d, origin))
        _ = d.update(sample(origin + 200 * ms, bytes: 1_000_000))
        XCTAssertNil(d.update(sample(origin + 400 * ms, bytes: 450_000)), "18 of 28 Mbit/s delivered is not under half")
    }

    /// 200 ms after a cut, frames still given up and none completed (the refresh did not fit through the cut): 0.7 x
    /// again, inside the hold; frames completing again stop it.
    func testAPictureThatDoesNotComeBackAfterACutIsCutAgain() {
        func frozen(_ t: UInt64, completed: Int = 0) -> RateSample {
            RateSample(nowNs: t, framesGivenUp: 2, fragmentsReceived: 150, framesCompleted: completed, deliveredBps: 6e6,
                       producedBps: 20e6, producedRecentBps: 20e6, bytesReceived: 150_000)
        }
        var c = RateController(ceilingBps: 20_000_000)
        _ = c.update(clean(c, origin))
        XCTAssertEqual(c.update(frozen(origin + 200 * ms)), 5_100_000)
        XCTAssertNil(c.update(frozen(origin + 300 * ms)), "100 ms after the cut")
        XCTAssertEqual(c.update(frozen(origin + 400 * ms)), 3_570_000)
        XCTAssertEqual(c.reason, .frozen)
        XCTAssertNil(c.update(frozen(origin + 600 * ms, completed: 3)), "frames completed: the picture is back")
    }

    /// A sample with over 20 % asked again (of at least 100 fragments) is trouble at once, however clean the second before.
    func testASharpLossIsTroubleAtOnce() {
        var c = RateController(ceilingBps: 100_000_000)
        run(&c, from: origin, to: origin + 800 * ms)
        XCTAssertNil(c.update(RateSample(nowNs: origin + 1000 * ms, fragmentsAsked: 30, fragmentsReceived: 99, framesCompleted: 12, deliveredBps: 50e6)),
                     "99 fragments are too few to judge")
        XCTAssertNotNil(c.update(RateSample(nowNs: origin + 1100 * ms, fragmentsAsked: 164, fragmentsReceived: 211, deliveredBps: 50e6)))
    }

    /// Trouble while climbing back under the memory: the memory becomes the lower of that rate and what the link delivered.
    func testTroubleUnderTheMemoryLowersItToWhatTheLinkDelivered() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        XCTAssertEqual(trouble(&c, origin + 200 * ms, delivered: 40e6), 34_000_000)
        XCTAssertEqual(c.memoryBps, 40_000_000, "the start never ran clean: what the link delivered")
        run(&c, from: origin + 200 * ms, to: origin + 6200 * ms)
        XCTAssertLessThanOrEqual(c.rateBps, 36_000_000)
        XCTAssertGreaterThan(c.rateBps, 34_000_000)
        _ = trouble(&c, origin + 6400 * ms, delivered: 23e6)
        XCTAssertEqual(c.memoryBps, 23_000_000)
        run(&c, from: origin + 6400 * ms, to: origin + 20 * sec)
        XCTAssertEqual(c.rateBps, 20_700_000, "the climb back aims at 90 % of what the link delivered")
    }

    /// Trouble below the memory that a queue cut first: a later cut in the same episode that shows the link lowers the
    /// memory to what the link delivered.
    func testALaterLinkLimitedCutInAnEpisodeUnderTheMemoryLowersIt() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        _ = trouble(&c, origin + 200 * ms, delivered: 40e6)
        XCTAssertEqual(c.memoryBps, 40_000_000)
        run(&c, from: origin + 200 * ms, to: origin + 6200 * ms)
        let rate = Double(c.rateBps)
        XCTAssertLessThan(rate, 40e6)
        XCTAssertNotNil(c.update(clean(c, origin + 6400 * ms, floorMs: 40)), "a queue cut")
        XCTAssertEqual(c.memoryBps, UInt32(rate), "the memory is the rate the queue episode began at")
        XCTAssertNotNil(c.update(RateSample(nowNs: origin + 7400 * ms, fragmentsAsked: 300, fragmentsReceived: 1000,
                                            framesCompleted: 10, deliveredBps: 20e6, producedBps: 30e6, producedRecentBps: 30e6,
                                            rttFloorNs: 40_000_000)))
        XCTAssertEqual(c.memoryBps, 20_000_000)
    }

    /// Cuts while trouble goes on (no clean second between them) are one episode: the memory stays at the rate it began at.
    func testTheMemoryIsTheRateAnEpisodeBeganAt() {
        var c = RateController(ceilingBps: 100_000_000)
        var t = atCeiling(&c)
        for _ in 0..<20 { t += RateController.samplePeriodNs; _ = trouble(&c, t) }
        XCTAssertGreaterThan(c.cuts, 3)
        XCTAssertEqual(c.memoryBps, 100_000_000, "100 ran clean for a second")
        var d = RateController(ceilingBps: 100_000_000)
        _ = d.update(clean(d, origin))
        t = origin
        for _ in 0..<20 { t += RateController.samplePeriodNs; _ = trouble(&d, t) }
        XCTAssertEqual(d.memoryBps, 50_000_000, "the start never ran clean, no link evidence: the rate the episode began at")
    }

    /// The narrow scenario's numbers: starts at 50, trouble at once with about 22 delivered, cut walks to 12. The start
    /// never ran clean, so the memory is what the link delivered; the climb back never passes it.
    func testARateThatNeverRanCleanIsNoMemory() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        var t = origin
        for _ in 0..<40 { t += RateController.samplePeriodNs; _ = trouble(&c, t, delivered: 22e6) }
        XCTAssertLessThan(c.rateBps, 20_000_000, "walks down")
        XCTAssertEqual(c.memoryBps, 22_000_000, "what the link delivered, not the 50 the episode began at")
        let low = c.rateBps
        let changes = run(&c, from: t, to: t + 25 * sec)
        XCTAssertGreaterThan(changes.count, 0, "no climb back")
        XCTAssertTrue(changes.allSatisfy { $0.bps <= 22_000_000 }, "the climb passed the link: \(changes), from \(low)")
    }

    /// A transient at an unproven rate (loss, delivered close to produced: no link evidence): the memory is the rate the
    /// episode began at, so the climb goes back to 90 % of it, not held at the cut.
    func testATransientAtAnUnprovenRateClimbsBack() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        let r = c.update(RateSample(nowNs: origin + 200 * ms, fragmentsAsked: 300, fragmentsReceived: 1000, framesCompleted: 10,
                                    deliveredBps: 48e6, producedBps: 50e6, producedRecentBps: 50e6, rttFloorNs: 8_000_000))
        XCTAssertEqual(r, 35_000_000)
        XCTAssertEqual(c.memoryBps, 50_000_000, "no link evidence: the rate the episode began at")
        run(&c, from: origin + 200 * ms, to: origin + 12 * sec)
        XCTAssertEqual(c.rateBps, 45_000_000, "back to 90 % of 50 in the return steps")
    }

    /// The same, then a sample of the episode that shows the link (about 22): the memory becomes that; the climb stays under it.
    func testALaterSampleOfAnUnprovenEpisodeLowersTheMemoryToTheLink() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        _ = c.update(RateSample(nowNs: origin + 200 * ms, fragmentsAsked: 300, fragmentsReceived: 1000, framesCompleted: 10,
                                deliveredBps: 48e6, producedBps: 50e6, producedRecentBps: 50e6, rttFloorNs: 8_000_000))
        XCTAssertEqual(c.memoryBps, 50_000_000)
        XCTAssertNotNil(c.update(RateSample(nowNs: origin + 1000 * ms, fragmentsAsked: 300, fragmentsReceived: 1000,
                                            framesCompleted: 10, deliveredBps: 22e6, producedBps: 35e6, producedRecentBps: 35e6,
                                            rttFloorNs: 8_000_000)))
        XCTAssertEqual(c.memoryBps, 22_000_000, "the link shown later in the same episode")
        let changes = run(&c, from: origin + 1000 * ms, to: origin + 25 * sec)
        XCTAssertGreaterThan(changes.count, 0, "no climb back")
        XCTAssertTrue(changes.allSatisfy { $0.bps <= 22_000_000 }, "the climb passed the link: \(changes)")
    }

    /// The dip's return: 40 ran clean for a second, the link falls to 8 and comes back; the memory stays 40 and the
    /// climb aims at 36 in four steps, one per second after the 5 s hold.
    func testARateThatRanCleanStaysTheMemory() {
        var c = RateController(ceilingBps: 40_000_000)
        XCTAssertEqual(c.rateBps, 20_000_000)
        var t = origin
        _ = c.update(clean(c, t))
        run(&c, from: t, to: t + 6 * sec)
        t += 6 * sec
        XCTAssertEqual(c.rateBps, 40_000_000)
        t += 200 * ms
        XCTAssertNotNil(trouble(&c, t, delivered: 8e6))
        XCTAssertEqual(c.memoryBps, 40_000_000)
        let changes = run(&c, from: t, to: t + 12 * sec)
        let back = changes.first { $0.bps >= 36_000_000 }.map { Double($0.at - t) / 1e9 } ?? .infinity
        XCTAssertLessThanOrEqual(back, 9.5, "back to 36 after \(back) s: \(changes)")
        XCTAssertGreaterThan(c.rateBps, 30_000_000)
    }

    /// No increase within 5 s of a cut, whatever the samples say.
    func testNoIncreaseWithinFiveSecondsOfACut() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        _ = trouble(&c, origin + 200 * ms)
        let changes = run(&c, from: origin + 200 * ms, to: origin + 5 * sec)
        XCTAssertTrue(changes.isEmpty, "\(changes)")
    }

    /// A sample long after the one before (the session was suspended), or one with nothing received (a stall), is no
    /// evidence: no cut, no increase, even with a frame given up in it.
    func testLateOrEmptySamplesChangeNothingByThemselves() {
        var c = RateController(ceilingBps: 100_000_000)
        run(&c, from: origin, to: origin + 800 * ms)
        let rate = c.rateBps
        XCTAssertNil(c.update(RateSample(nowNs: origin + 3 * sec, fragmentsReceived: 1000, framesCompleted: 12, deliveredBps: 50e6)),
                     "a sample 2.2 s late raised the rate")
        XCTAssertNil(c.update(RateSample(nowNs: origin + 3 * sec + 200 * ms, framesGivenUp: 2, fragmentsReceived: 0,
                                         deliveredBps: 0)), "a stall cut the rate")
        XCTAssertNil(c.update(RateSample(nowNs: origin + 6 * sec, framesGivenUp: 1, fragmentsReceived: 900,
                                         deliveredBps: 0)), "a late sample with a frame given up cut the rate")
        XCTAssertEqual(c.rateBps, rate)
        XCTAssertEqual(c.cuts, 0)
    }

    /// The climb back's target is a whole number of bit/s: a memory whose 90 % is fractional still reaches it and probes.
    func testTheClimbBackReachesItsTargetWhateverTheMemoryIs() {
        for m in [19_912_340.0, 19_912_346.0] {
            var c = RateController(ceilingBps: 50_000_000)
            _ = c.update(clean(c, origin))
            _ = trouble(&c, origin + 200 * ms, delivered: m)
            let changes = run(&c, from: origin + 200 * ms, to: origin + 120 * sec)
            XCTAssertGreaterThan(c.rateBps, UInt32(m), "m=\(m): no probe in 120 clean seconds: \(changes.map(\.bps))")
        }
    }

    /// A loss with the link delivering what was produced and no queue, under a measured memory, cuts but leaves the memory.
    func testALossWithoutALinkSignOrAQueueKeepsAMeasuredMemory() {
        var c = RateController(ceilingBps: 40_000_000)
        var t = origin
        _ = c.update(clean(c, t))
        run(&c, from: t, to: t + 6 * sec)
        t += 6 * sec + 200 * ms
        XCTAssertNotNil(trouble(&c, t, delivered: 8e6))
        XCTAssertEqual(c.memoryBps, 40_000_000)
        run(&c, from: t, to: t + 12 * sec)
        t += 12 * sec + 200 * ms
        XCTAssertEqual(c.rateBps, 36_000_000)
        XCTAssertEqual(trouble(&c, t), 25_200_000, "0.7 x 36")
        XCTAssertEqual(c.memoryBps, 40_000_000, "a loss with the link delivering what was produced lowered the memory")
        run(&c, from: t, to: t + 12 * sec)
        XCTAssertEqual(c.rateBps, 36_000_000, "back to 90 % of the memory")
    }

    /// A picture filling 60 % of the rate does not probe above the memory and does not fade it: it proves nothing about the link.
    func testAPictureFillingUnderNinetyPercentNeitherProbesNorFadesTheMemory() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        var t = origin + 200 * ms
        XCTAssertEqual(trouble(&c, t, delivered: 40e6), 34_000_000)
        var changes: [UInt32] = []
        for _ in 0..<(150 * 5) {
            t += RateController.samplePeriodNs
            let r = Double(c.rateBps)
            if let n = c.update(RateSample(nowNs: t, fragmentsReceived: 1000, framesCompleted: 12, deliveredBps: 0.6 * r,
                                           producedBps: 0.6 * r, producedRecentBps: 0.6 * r, rttFloorNs: 8_000_000)) { changes.append(n) }
        }
        XCTAssertEqual(c.rateBps, 36_000_000, "\(changes)")
        XCTAssertEqual(c.memoryBps, 40_000_000)
    }

    /// A loss-only sample (nothing asked of the link's queue, the link delivering what was produced) at the current rate.
    private func lossOnly(_ c: RateController, _ t: UInt64) -> RateSample {
        let r = Double(c.rateBps)
        return RateSample(nowNs: t, fragmentsAsked: 300, fragmentsReceived: 1000, framesCompleted: 10,
                          deliveredBps: r, producedBps: r, producedRecentBps: r, rttFloorNs: 8_000_000)
    }

    /// A guessed memory (the rate an unproven episode began at) is lowered by one later loss-only episode, to the rate it
    /// began at; the memory is then measured, and a further loss-only episode leaves it.
    func testAGuessedMemoryIsLoweredOnceByALossOnlyEpisode() {
        var c = RateController(ceilingBps: 100_000_000)
        _ = c.update(clean(c, origin))
        _ = c.update(RateSample(nowNs: origin + 200 * ms, fragmentsAsked: 300, fragmentsReceived: 1000, framesCompleted: 10,
                                deliveredBps: 48e6, producedBps: 50e6, producedRecentBps: 50e6, rttFloorNs: 8_000_000))
        XCTAssertEqual(c.memoryBps, 50_000_000, "the guess")
        var t = origin + 12 * sec
        run(&c, from: origin + 200 * ms, to: t)
        XCTAssertEqual(c.rateBps, 45_000_000)
        t += 200 * ms
        XCTAssertNotNil(c.update(lossOnly(c, t)))
        XCTAssertEqual(c.memoryBps, 45_000_000, "a guess survived a loss-only episode below it")
        run(&c, from: t, to: t + 12 * sec)
        t += 12 * sec + 200 * ms
        XCTAssertEqual(c.rateBps, 40_500_000, "back to 90 % of 45")
        XCTAssertNotNil(c.update(lossOnly(c, t)))
        XCTAssertEqual(c.memoryBps, 45_000_000, "the lowered memory is measured: a second loss-only episode leaves it")
    }

    /// Full seconds above the memory count toward its fade; a second where the encoder fills under 0.9 of the rate
    /// pauses the count, it does not restart it.
    func testAQuietSecondAboveTheMemoryPausesTheFadeClock() {
        var c = RateController(ceilingBps: 100_000_000)
        var t = probeAboveMemory(&c)
        func feed(_ seconds: Int, fill: Double) {
            for _ in 0..<(seconds * 5) {
                t += RateController.samplePeriodNs
                let r = Double(c.rateBps)
                _ = c.update(RateSample(nowNs: t, fragmentsReceived: 1000, framesCompleted: 12, deliveredBps: fill * r,
                                        producedBps: fill * r, producedRecentBps: fill * r, rttFloorNs: 8_000_000))
            }
        }
        feed(40, fill: 1)
        XCTAssertNotNil(c.memoryBps)
        feed(5, fill: 0.6)
        XCTAssertNotNil(c.memoryBps, "a quiet stretch faded the memory")
        feed(15, fill: 1)
        XCTAssertNotNil(c.memoryBps, "55 full seconds in total")
        feed(10, fill: 1)
        XCTAssertNil(c.memoryBps, "65 full seconds in total with a quiet second between: the memory did not fade")
    }

    // MARK: live ceiling (a change while the session runs)

    /// A controller that ran into trouble at the 50 Mbit/s ceiling (memory 50) and climbed back to 45; the time it is at.
    private func atFortyFiveWithMemory() -> (RateController, UInt64) {
        var c = RateController(ceilingBps: 50_000_000)
        var t = atCeiling(&c)
        t += RateController.samplePeriodNs
        _ = trouble(&c, t)
        XCTAssertEqual(c.rateBps, 35_000_000)
        XCTAssertEqual(c.memoryBps, 50_000_000)
        run(&c, from: t, to: t + 20 * sec)
        XCTAssertEqual(c.rateBps, 45_000_000, "back to 90 % of the memory")
        return (c, t + 20 * sec)
    }

    /// 50 -> 20 Mbit/s while at 45: the rate is 20 at once; the next decisions stay at most 20; back to 50 there is no jump.
    func testALoweredCeilingCutsAtOnceAndARaisedOneDoesNotJump() {
        var (c, t) = atFortyFiveWithMemory()
        let cuts = c.cuts
        XCTAssertEqual(c.setCeiling(20_000_000), 20_000_000, "the new rate is reported at once")
        XCTAssertEqual(c.ceilingBps, 20_000_000)
        XCTAssertEqual(c.rateBps, 20_000_000)
        XCTAssertEqual(c.cuts, cuts, "a lowered ceiling is the user's choice, not a cut")
        for change in run(&c, from: t, to: t + 40 * sec) { XCTAssertLessThanOrEqual(change.bps, 20_000_000) }
        XCTAssertEqual(c.rateBps, 20_000_000, "the memory above the ceiling does not lift the rate over it")
        t += 40 * sec
        XCTAssertNil(c.setCeiling(50_000_000), "a raised ceiling changes nothing by itself")
        XCTAssertEqual(c.rateBps, 20_000_000)
        var previous = Double(c.rateBps), previousAt: UInt64?
        let changes = run(&c, from: t, to: t + 12 * sec)
        XCTAssertFalse(changes.isEmpty, "the normal climb goes on")
        for ch in changes {
            XCTAssertLessThanOrEqual(Double(ch.bps), previous * 1.25 + 1, "a jump of more than 25 %: \(changes)")
            if let at = previousAt { XCTAssertGreaterThanOrEqual(ch.at - at, sec, "one step a second at most") }
            previous = Double(ch.bps); previousAt = ch.at
        }
        XCTAssertLessThanOrEqual(c.rateBps, 45_000_000, "toward 90 % of the memory (50), no further")
    }

    func testALoweredCeilingAboveTheRateChangesNothingNow() {
        var c = RateController(ceilingBps: 100_000_000)
        XCTAssertEqual(c.rateBps, 50_000_000)
        XCTAssertNil(c.setCeiling(80_000_000))
        XCTAssertEqual(c.rateBps, 50_000_000)
        XCTAssertEqual(c.ceilingBps, 80_000_000)
        XCTAssertEqual(c.setCeiling(1), RateController.floorBps, "never under the floor")
        XCTAssertEqual(c.ceilingBps, RateController.floorBps)
    }

    /// After the ceiling went up again no change is more than + 25 % and no two are under a second apart.
    private func assertNoJump(_ changes: [(at: UInt64, bps: UInt32)], from rate: UInt32, _ why: String) {
        var previous = Double(rate), previousAt: UInt64?
        for ch in changes {
            XCTAssertLessThanOrEqual(Double(ch.bps), previous * 1.25 + 1, "\(why): a jump of more than 25 %: \(changes)")
            if let at = previousAt { XCTAssertGreaterThanOrEqual(ch.at - at, sec, "\(why): one step a second at most") }
            previous = Double(ch.bps); previousAt = ch.at
        }
    }

    /// (a) A ceiling lowered while the rate probes above the memory: the rate is the ceiling, the memory stays, nothing
    /// goes over the ceiling afterwards, and raising it again does not jump.
    func testACeilingLoweredDuringAProbe() {
        var c = RateController(ceilingBps: 100_000_000)
        var t = atCeiling(&c)  // 100
        t += RateController.samplePeriodNs
        _ = trouble(&c, t)  // memory 100, cut to 70
        XCTAssertEqual(c.memoryBps, 100_000_000)
        t += 20 * sec; run(&c, from: t - 20 * sec, to: t)  // back to 90
        XCTAssertEqual(c.rateBps, 90_000_000)
        c.setCeiling(150_000_000)
        var probed = false
        var u = t
        while u < t + 60 * sec && !probed { u += RateController.samplePeriodNs; if c.update(clean(c, u)) != nil, c.reason == .probe { probed = true } }
        XCTAssertTrue(probed, "the probe above the memory began")
        let probing = c.rateBps
        XCTAssertGreaterThan(probing, 90_000_000)
        XCTAssertEqual(c.setCeiling(80_000_000), 80_000_000)
        XCTAssertEqual(c.memoryBps, 100_000_000, "the memory is not touched")
        for ch in run(&c, from: u, to: u + 90 * sec) { XCTAssertLessThanOrEqual(ch.bps, 80_000_000) }
        XCTAssertEqual(c.rateBps, 80_000_000)
        u += 90 * sec
        c.setCeiling(150_000_000)
        assertNoJump(run(&c, from: u, to: u + 12 * sec), from: c.rateBps, "after the probe")
    }

    /// (b) A ceiling lowered while the memory fades (the rate above it, clean seconds counting): the rate falls under the
    /// memory, the count stops, the memory is not lost to the seconds spent before.
    func testACeilingLoweredDuringAFade() {
        var c = RateController(ceilingBps: 100_000_000)
        var t = atCeiling(&c)
        t += RateController.samplePeriodNs
        _ = trouble(&c, t)  // memory 100
        run(&c, from: t, to: t + 60 * sec); t += 60 * sec
        c.setCeiling(150_000_000)
        run(&c, from: t, to: t + 50 * sec); t += 50 * sec  // above the memory, the fade count running
        XCTAssertGreaterThan(c.rateBps, 100_000_000)
        XCTAssertEqual(c.memoryBps, 100_000_000, "not faded yet")
        c.setCeiling(80_000_000)
        for ch in run(&c, from: t, to: t + 120 * sec) { XCTAssertLessThanOrEqual(ch.bps, 80_000_000) }
        XCTAssertEqual(c.memoryBps, 100_000_000, "a rate under the memory does not fade it")
        t += 120 * sec
        c.setCeiling(150_000_000)
        assertNoJump(run(&c, from: t, to: t + 12 * sec), from: c.rateBps, "after the fade")
    }

    /// (c) A ceiling lowered inside a cut's hold: the rate is the ceiling; the hold's no-increase time still runs when the
    /// ceiling goes up again; trouble inside the hold cuts nothing by itself.
    func testACeilingLoweredInsideACutHold() {
        var c = RateController(ceilingBps: 50_000_000)
        var t = atCeiling(&c)
        t += RateController.samplePeriodNs
        XCTAssertEqual(trouble(&c, t), 35_000_000)
        XCTAssertEqual(c.setCeiling(20_000_000), 20_000_000)
        XCTAssertNil(trouble(&c, t + 100 * ms), "inside the hold: no further cut, as before")
        XCTAssertEqual(c.rateBps, 20_000_000)
        c.setCeiling(50_000_000)
        let early = run(&c, from: t, to: t + 4 * sec)
        XCTAssertTrue(early.isEmpty, "no increase within 5 s of the cut: \(early)")
        let later = run(&c, from: t + 4 * sec, to: t + 16 * sec)
        XCTAssertFalse(later.isEmpty, "the normal climb goes on afterwards")
        assertNoJump(later, from: 20_000_000, "after the hold")
    }

    /// (d) Trouble right after a lowering: the cut stays under the new ceiling, the memory is never raised, and raising the
    /// ceiling later does not jump.
    func testTroubleRightAfterALoweredCeiling() {
        var (c, t) = atFortyFiveWithMemory()
        let memory = c.memoryBps!
        XCTAssertEqual(c.setCeiling(20_000_000), 20_000_000)
        t += RateController.samplePeriodNs
        let cut = trouble(&c, t)
        XCTAssertNotNil(cut)
        XCTAssertLessThan(cut ?? .max, 20_000_000, "a cut from the new ceiling")
        XCTAssertGreaterThanOrEqual(cut ?? 0, RateController.floorBps)
        XCTAssertLessThanOrEqual(c.memoryBps ?? 0, memory, "the memory is not raised")
        for ch in run(&c, from: t, to: t + 60 * sec) { XCTAssertLessThanOrEqual(ch.bps, 20_000_000) }
        t += 60 * sec
        c.setCeiling(50_000_000)
        // after trouble the return rule applies (4 equal steps to 90 % of the memory, one a second), as without a lowering
        let from = Double(c.rateBps), cutRate = Double(cut ?? 0)
        let step = max((0.9 * Double(c.memoryBps ?? memory) - cutRate) / 4, 500_000)
        var previous = from, previousAt: UInt64?
        for ch in run(&c, from: t, to: t + 12 * sec) {
            XCTAssertLessThanOrEqual(Double(ch.bps), previous + step + 1, "a step bigger than the return rule's")
            if let at = previousAt { XCTAssertGreaterThanOrEqual(ch.at - at, sec) }
            previous = Double(ch.bps); previousAt = ch.at
        }
        XCTAssertLessThanOrEqual(c.memoryBps ?? 0, memory)
    }
}
