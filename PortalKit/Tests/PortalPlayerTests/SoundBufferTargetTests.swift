import XCTest
@testable import PortalPlayer

final class SoundBufferTargetTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    /// Feeds arrivals every `gapMs` from `from` for `seconds`; returns the end time.
    private func steady(_ t: inout SoundBufferTarget, from: UInt64, gapMs: Double, seconds: Double) -> UInt64 {
        var now = from
        let end = from + UInt64(seconds * 1e9)
        while now < end { t.arrival(atNs: now); now += UInt64(gapMs * 1e6) }
        return now
    }

    func testBeforeOneSecondTheStartValueHolds() {
        var t = SoundBufferTarget()
        let end = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 0.5)
        XCTAssertEqual(t.wantedMs(atNs: end), 50)
        var empty = SoundBufferTarget()
        XCTAssertEqual(empty.wantedMs(atNs: 5 * ms), 50, "nothing heard yet")
    }

    func testSteadyFiveMsGapsReachTheFloor() {
        var t = SoundBufferTarget()
        let end = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 1.5)
        XCTAssertEqual(t.wantedMs(atNs: end), 20)
    }

    /// Bursts of three every 16.7 ms and a 40 ms gap now and then: p99 gap 40 + 10.
    func testBurstsWithGapsUpTo40Ms() {
        var t = SoundBufferTarget()
        var now: UInt64 = 1_000 * ms
        for burst in 0..<400 {
            for _ in 0..<3 { t.arrival(atNs: now) }
            now += burst % 20 == 19 ? 40 * ms : 16_700_000
        }
        let w = t.wantedMs(atNs: now)
        XCTAssertGreaterThanOrEqual(w, 45); XCTAssertLessThanOrEqual(w, 55)
    }

    func testAnUnderrunRaisesAtOnceAndFallsBackSlowlyAfterTenSeconds() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 2)
        XCTAssertEqual(t.wantedMs(atNs: now), 20)
        let at = now
        t.underrun(atNs: at)
        XCTAssertEqual(t.wantedMs(atNs: at), 30, "+10 ms at once")
        var last = 30
        var reachedFloorAt: UInt64?
        while now < at + 40_000 * ms {
            t.arrival(atNs: now)
            now += 5 * ms
            let w = t.wantedMs(atNs: now)
            if now < at + 30_000 * ms { XCTAssertEqual(w, 30, "held for 30 s") }
            XCTAssertLessThanOrEqual(last - w, 1, "falls at most 5 ms a second (checked every 5 ms)")
            if w == 20, reachedFloorAt == nil { reachedFloorAt = now }
            last = w
        }
        XCTAssertGreaterThanOrEqual(reachedFloorAt ?? 0, at + 31_900 * ms, "10 ms down at 5 ms a second takes 2 s after the 30 s hold")
        XCTAssertEqual(last, 20)
    }

    func testFurtherUnderrunsAddAndRestartTheHold() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 2)
        t.underrun(atNs: now)
        let second = now + 20_000 * ms
        now = steady(&t, from: now, gapMs: 5, seconds: 20)
        t.underrun(atNs: second)
        XCTAssertEqual(t.wantedMs(atNs: second), 40)
        let later = steady(&t, from: now, gapMs: 5, seconds: 25)   // 45 s after the first, 25 s after the second
        XCTAssertEqual(t.wantedMs(atNs: later), 40, "the hold restarted")
    }

    /// Bursts of three every 16.7 ms; at each `events` time the next burst comes `gapMs` late. Calls `each(now)` per burst.
    private func bursts(_ t: inout SoundBufferTarget, from: UInt64, seconds: Double, events: [Double], gapMs: Double,
                        each: (inout SoundBufferTarget, UInt64) -> Void) {
        var now = from
        var pending = events.map { from + UInt64($0 * 1e9) }
        let end = from + UInt64(seconds * 1e9)
        while now < end {
            for _ in 0..<3 { t.arrival(atNs: now) }
            each(&t, now)
            if let e = pending.first, now >= e { pending.removeFirst(); now += UInt64(gapMs * 1e6) } else { now += 16_700_000 }
        }
    }

    /// A rise of 45 ms once every 10 s is under 1 % of the gaps; the second-largest gap of 30 s sees it.
    func testARiseEveryTenSecondsSettlesAt50AndStays() {
        var t = SoundBufferTarget()
        let start: UInt64 = 1_000 * ms
        var settledAt: Double?
        bursts(&t, from: start, seconds: 70, events: [5, 15, 25, 35, 45, 55, 65], gapMs: 45) { t, now in
            let sec = Double(now - start) / 1e9
            let w = t.wantedMs(atNs: now)
            if sec >= 21 { XCTAssertTrue((48...52).contains(w), "\(w) ms at \(sec) s") }
            if settledAt == nil, (48...52).contains(w) { settledAt = sec }
        }
        XCTAssertLessThanOrEqual(settledAt ?? 99, 21)
    }

    /// One single outlier in 30 s is ignored by both parts.
    func testOneSingleLongGapChangesNothingLasting() {
        var t = SoundBufferTarget()
        let start: UInt64 = 1_000 * ms
        bursts(&t, from: start, seconds: 60, events: [5], gapMs: 110) { t, now in
            let sec = Double(now - start) / 1e9
            let w = t.wantedMs(atNs: now)
            if sec >= 2 { XCTAssertLessThanOrEqual(w, 30, "\(w) ms at \(sec) s") }
        }
    }

    /// Underruns every 3 s: the wanted value rises and stays up; it never falls by more than 5 ms (no sawtooth).
    func testUnderrunsEveryThreeSecondsRaiseAndHold() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 2)   // warmed up: 20 ms
        var peak = 0, nextUnderrun = now + 3_000 * ms
        var last = 0
        while now < 63_000 * ms {
            t.arrival(atNs: now)
            if now >= nextUnderrun { t.underrun(atNs: now); nextUnderrun += 3_000 * ms }
            now += 5 * ms
            last = t.wantedMs(atNs: now)
            peak = max(peak, last)
            XCTAssertGreaterThanOrEqual(last, peak - 5, "fell from \(peak) to \(last)")
        }
        XCTAssertEqual(last, 100)
    }

    /// A pause (gap over 500 ms) starts the warm-up over: 50 ms at once, windows emptied, the pause's own underrun adds nothing.
    func testAPauseStartsOverAndItsUnderrunAddsNothing() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 60)
        XCTAssertEqual(t.wantedMs(atNs: now), 20)
        now += 30_000 * ms
        t.underrun(atNs: now)          // the render thread ran dry; seen at the first push, before the arrival
        t.arrival(atNs: now)
        t.underrun(atNs: now)
        XCTAssertEqual(t.wantedMs(atNs: now), 50)
        now = steady(&t, from: now + 5 * ms, gapMs: 5, seconds: 0.5)
        XCTAssertEqual(t.wantedMs(atNs: now), 50, "still warming up")
        now = steady(&t, from: now, gapMs: 5, seconds: 1)
        XCTAssertEqual(t.wantedMs(atNs: now), 20, "no +10 from the pause")
    }

    /// A pause also forgets the underrun raise (and its hold): after it the value is the 50 ms start and nothing else.
    func testAPauseClearsTheUnderrunRaise() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 3)
        t.underrun(atNs: now); t.underrun(atNs: now)
        XCTAssertEqual(t.wantedMs(atNs: now), 40)
        now += 20_000 * ms                       // the pause: both raises would still be held
        t.arrival(atNs: now)
        XCTAssertEqual(t.wantedMs(atNs: now), 50)
        now = steady(&t, from: now + 5 * ms, gapMs: 5, seconds: 1.5)
        XCTAssertEqual(t.wantedMs(atNs: now), 20, "the old raises are gone")
        t.underrun(atNs: now)
        XCTAssertEqual(t.wantedMs(atNs: now), 30, "an underrun 1.5 s after the resume counts")
    }

    func testAGapThenHalfASecondIsStillWarmingUp() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 3)
        now += 2_000 * ms
        now = steady(&t, from: now, gapMs: 5, seconds: 0.5)
        XCTAssertEqual(t.wantedMs(atNs: now), 50)
    }

    /// An underrun a little after the pause is real and counts (only the first second is exempt).
    func testAnUnderrunTwoSecondsAfterAPauseCounts() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 3)
        now += 2_000 * ms
        now = steady(&t, from: now, gapMs: 5, seconds: 2)
        t.underrun(atNs: now)
        XCTAssertEqual(t.wantedMs(atNs: now), 30)
    }

    func testTheWantedValueIsClampedAt100() {
        var t = SoundBufferTarget()
        let end = steady(&t, from: 1_000 * ms, gapMs: 150, seconds: 4)
        XCTAssertEqual(t.wantedMs(atNs: end), 100)
        for _ in 0..<20 { t.underrun(atNs: end) }
        XCTAssertEqual(t.wantedMs(atNs: end), 100)
    }

    func testAGapOverHalfASecondIsNotAMeasurement() {
        var t = SoundBufferTarget()
        var now = steady(&t, from: 1_000 * ms, gapMs: 5, seconds: 2)
        now += 2_000 * ms
        now = steady(&t, from: now, gapMs: 5, seconds: 2)
        XCTAssertEqual(t.wantedMs(atNs: now), 20)
    }
}
