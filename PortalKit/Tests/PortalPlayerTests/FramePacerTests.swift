import XCTest
@testable import PortalPlayer

final class FramePacerTests: XCTestCase {
    func testImmediateSteady() {
        var p = FramePacer<Int>(mode: .immediate)
        for n in 1...60 {
            XCTAssertEqual(p.push(n), n)
            XCTAssertNil(p.refresh())
        }
        let c = p.takeCounts()
        XCTAssertEqual(c.shown, 60); XCTAssertEqual(c.late, 0); XCTAssertEqual(c.empty, 0)
        let again = p.takeCounts()
        XCTAssertEqual(again.shown, 0, "taking resets")
    }

    /// Two pictures land in one interval, none in the next: the second waits for the refresh, nothing is lost or empty.
    func testImmediateBunchedHoldsSecond() {
        var p = FramePacer<Int>(mode: .immediate)
        XCTAssertEqual(p.push(1), 1)
        XCTAssertNil(p.push(2), "held")
        XCTAssertEqual(p.refresh(), 2, "shown at the refresh")
        XCTAssertNil(p.refresh(), "its own interval had a picture: not empty")
        let c = p.takeCounts()
        XCTAssertEqual(c.shown, 2); XCTAssertEqual(c.late, 0); XCTAssertEqual(c.empty, 0)
    }

    /// The alternating 2 / 0 pattern: every picture shown, every refresh has one.
    func testImmediateAlternatingPairs() {
        var p = FramePacer<Int>(mode: .immediate)
        var n = 0, out: [Int] = []
        for _ in 0..<30 {
            n += 1; if let f = p.push(n) { out.append(f) }
            n += 1; if let f = p.push(n) { out.append(f) }
            if let f = p.refresh() { out.append(f) }
            if let f = p.refresh() { out.append(f) }
        }
        XCTAssertEqual(out, Array(1...60), "in order, none skipped")
        let c = p.takeCounts()
        XCTAssertEqual(c.shown, 60); XCTAssertEqual(c.late, 0); XCTAssertEqual(c.empty, 0)
    }

    func testImmediateThirdReplacesHeld() {
        var p = FramePacer<Int>(mode: .immediate)
        XCTAssertEqual(p.push(1), 1)
        XCTAssertNil(p.push(2)); XCTAssertNil(p.push(3))
        XCTAssertEqual(p.refresh(), 3)
        let c = p.takeCounts()
        XCTAssertEqual(c.late, 1); XCTAssertEqual(c.shown, 1); XCTAssertEqual(c.empty, 0)
    }

    /// A picture after the held one was taken is in the same interval as it: held again.
    func testImmediatePictureAfterHeldIsHeld() {
        var p = FramePacer<Int>(mode: .immediate)
        _ = p.push(1); _ = p.push(2)
        XCTAssertEqual(p.refresh(), 2)
        XCTAssertNil(p.push(3), "the interval already has a picture")
        XCTAssertEqual(p.refresh(), 3)
        XCTAssertEqual(p.takeCounts().late, 0)
    }

    /// Held pictures go to the store when the mode changes to `smooth`, in order.
    func testSwitchToSmoothKeepsHeld() {
        var p = FramePacer<Int>(mode: .immediate)
        _ = p.push(1); _ = p.push(2)
        p.mode = .smooth
        XCTAssertNil(p.push(3))
        XCTAssertEqual(p.refresh(), 2)
        XCTAssertEqual(p.refresh(), 3)
    }

    func testSmoothBunched() {
        var p = FramePacer<Int>(mode: .smooth)
        var n = 0
        var shown: [Int] = []
        for _ in 0..<30 {
            n += 1; XCTAssertNil(p.push(n))
            n += 1; XCTAssertNil(p.push(n))
            if let f = p.refresh() { shown.append(f) }
            if let f = p.refresh() { shown.append(f) }
        }
        for (a, b) in zip(shown, shown.dropFirst()) { XCTAssertEqual(b, a + 1, "in order, none skipped") }
        let c = p.takeCounts()
        XCTAssertGreaterThanOrEqual(c.shown, 59)
        XCTAssertEqual(c.late, 0)
        XCTAssertLessThanOrEqual(c.empty, 1)
    }

    func testSmoothBoundsDelay() {
        var p = FramePacer<Int>(mode: .smooth)
        for n in 1...5 { XCTAssertNil(p.push(n)) }
        XCTAssertEqual(p.refresh(), 1)
        XCTAssertEqual(p.pending, 1)
        let c = p.takeCounts()
        XCTAssertEqual(c.late, 3)
        XCTAssertEqual(c.shown, 1)
        XCTAssertEqual(p.refresh(), 5, "the newest")
        XCTAssertNil(p.refresh())
    }

    func testSmoothStarved() {
        var p = FramePacer<Int>(mode: .smooth)
        XCTAssertNil(p.refresh())
        XCTAssertEqual(p.takeCounts().empty, 1)
        XCTAssertNil(p.push(7))
        XCTAssertEqual(p.refresh(), 7)
    }

    func testModeSwitchFlushes() {
        var p = FramePacer<Int>(mode: .smooth)
        for n in 1...4 { XCTAssertNil(p.push(n)) }
        p.mode = .immediate
        XCTAssertEqual(p.refresh(), 4, "the newest, once")
        XCTAssertEqual(p.takeCounts().late, 3, "the rest dropped as late")
        XCTAssertNil(p.refresh())
        XCTAssertEqual(p.push(5), 5)
        p.mode = .smooth
        XCTAssertNil(p.push(6))
        XCTAssertEqual(p.refresh(), 6)
    }

    func testResetDropsPendingAndCounts() {
        var p = FramePacer<Int>(mode: .smooth)
        _ = p.push(1); _ = p.refresh(); _ = p.refresh()
        _ = p.push(2)
        p.reset()
        XCTAssertNil(p.refresh())
        let c = p.takeCounts()
        XCTAssertEqual(c.shown, 0); XCTAssertEqual(c.late, 0); XCTAssertEqual(c.empty, 1)
    }

    /// An older stored picture must not follow a newer one that was shown at once.
    func testSwitchToImmediateDropsStoredBeforePush() {
        var p = FramePacer<Int>(mode: .smooth)
        XCTAssertNil(p.push(1)); XCTAssertNil(p.push(2))
        p.mode = .immediate
        XCTAssertEqual(p.push(3), 3)
        XCTAssertNil(p.refresh())
        XCTAssertEqual(p.takeCounts().late, 2)
    }

    // MARK: smooth keeps a second picture for a while (slack) instead of dropping it at once

    /// Nine times in every 60 refreshes two pictures land in one interval and none in the next. The first interval
    /// holds two, so one picture is always carried (the phase near the refresh edge).
    func testPairThenNothingDropsNothing() {
        var p = FramePacer<Int>(mode: .smooth)
        var arrivals = [2]
        for r in 1..<600 {
            if r % 60 < 54 && r % 6 == 0 { arrivals.append(2) }          // 9 pairs per 60 refreshes
            else if r > 1 && (r - 1) % 60 < 54 && (r - 1) % 6 == 0 { arrivals.append(0) }
            else { arrivals.append(1) }
        }
        var n = 0, pushed = 0, shownCount = 0
        for k in arrivals {
            for _ in 0..<k { n += 1; _ = p.push(n); pushed += 1 }
            if p.refresh() != nil { shownCount += 1 }
        }
        while p.pending > 0 { if p.refresh() != nil { shownCount += 1 } }
        let c = p.takeCounts()
        XCTAssertEqual(c.late, 0)
        XCTAssertEqual(shownCount, pushed, "every picture pushed is shown")
        XCTAssertLessThanOrEqual(c.empty, 1)
    }

    func testFasterSourceDropsAboutOneASecond() {
        var p = FramePacer<Int>(mode: .smooth)
        var n = 0, maxPending = 0
        for r in 0..<600 {
            n += 1; _ = p.push(n)
            if r % 60 == 59 { n += 1; _ = p.push(n) }   // 61 arrivals per 60 refreshes
            _ = p.refresh()
            maxPending = max(maxPending, p.pending)
        }
        let late = p.takeCounts().late
        XCTAssertGreaterThanOrEqual(late, 8); XCTAssertLessThanOrEqual(late, 12)
        XCTAssertLessThanOrEqual(maxPending, FramePacer<Int>.ceiling)
    }

    func testBurstIsCutAtOnce() {
        var p = FramePacer<Int>(mode: .smooth)
        for n in 1...10 { _ = p.push(n) }
        XCTAssertEqual(p.refresh(), 1, "the oldest")
        XCTAssertEqual(p.pending, FramePacer<Int>.target)
        XCTAssertEqual(p.takeCounts().late, 8)
    }

    func testSlackCountRestarts() {
        var p = FramePacer<Int>(mode: .smooth)
        var n = 0
        func push(_ k: Int) { for _ in 0..<k { n += 1; _ = p.push(n) } }
        push(3); _ = p.refresh()                              // over 1: two stored
        for _ in 0..<4 { push(1); _ = p.refresh() }           // over 5, still two stored
        XCTAssertEqual(p.pending, 2)
        _ = p.refresh()                                       // not over: the count resets
        XCTAssertEqual(p.pending, 1)
        push(2); _ = p.refresh()                              // over 1 again
        for _ in 0..<4 { push(1); _ = p.refresh() }           // over 5
        XCTAssertEqual(p.pending, 2)
        XCTAssertEqual(p.takeCounts().late, 0)
    }

    /// Immediate mode empties the store, so the smooth over-count must not survive a trip through it.
    func testOverCountIsForgottenInImmediateMode() {
        var p = FramePacer<Int>(mode: .smooth)
        var n = 0
        func push(_ k: Int) { for _ in 0..<k { n += 1; _ = p.push(n) } }
        push(3); _ = p.refresh()                              // over 1
        for _ in 0..<4 { push(1); _ = p.refresh() }           // over 5, two stored
        p.mode = .immediate
        _ = p.refresh()                                       // newest shown, one dropped late by immediate itself
        p.mode = .smooth
        push(3); _ = p.refresh()                              // over 1 again, not 6
        for _ in 0..<4 { push(1); _ = p.refresh() }           // over 5
        XCTAssertEqual(p.takeCounts().late, 1, "only what immediate mode dropped")
    }

    func testSlackIsExactlySixRefreshes() {
        XCTAssertEqual(FramePacer<Int>.slack, 6)
        var p = FramePacer<Int>(mode: .smooth)
        var n = 0
        func push(_ k: Int) { for _ in 0..<k { n += 1; _ = p.push(n) } }
        push(3); _ = p.refresh()                              // over 1
        for _ in 0..<4 { push(1); _ = p.refresh() }           // over 5: kept
        XCTAssertEqual(p.pending, 2)
        XCTAssertEqual(p.takeCounts().late, 0)
        push(1); _ = p.refresh()                              // over 6: dropped
        XCTAssertEqual(p.pending, FramePacer<Int>.target)
        XCTAssertEqual(p.takeCounts().late, 1)
    }

    func testCeilingBoundary() {
        var p = FramePacer<Int>(mode: .smooth)
        for n in 1...(FramePacer<Int>.ceiling + 1) { _ = p.push(n) }   // one is taken, ceiling stay
        _ = p.refresh()
        XCTAssertEqual(p.pending, FramePacer<Int>.ceiling, "exactly ceiling is kept")
        XCTAssertEqual(p.takeCounts().late, 0)
        var q = FramePacer<Int>(mode: .smooth)
        for n in 1...(FramePacer<Int>.ceiling + 2) { _ = q.push(n) }
        _ = q.refresh()
        XCTAssertEqual(q.pending, FramePacer<Int>.target, "ceiling + 1 is cut at once")
        XCTAssertEqual(q.takeCounts().late, FramePacer<Int>.ceiling + 1 - FramePacer<Int>.target)
    }
}
