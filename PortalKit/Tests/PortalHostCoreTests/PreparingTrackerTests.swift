#if os(macOS)
import XCTest
import PortalKit
@testable import PortalHostCore

/// The tracker takes time as an argument (nanoseconds); these tests never wait.
final class PreparingTrackerTests: XCTestCase {
    private func s(_ seconds: Double) -> UInt64 { UInt64(seconds * 1e9) }
    private func p(_ phase: UInt8, _ done: UInt32, _ total: UInt32) -> Preparing { Preparing(phase: phase, done: done, total: total) }

    private func launched() -> PreparingTracker {
        var t = PreparingTracker()
        t.launched(now: 0)
        return t
    }

    func testNothingIsPreparingBeforeALaunch() {
        XCTAssertEqual(PreparingTracker().state(now: s(10)), .none)
    }

    func testPreparingFromLaunchUntilTheFirstPicture() {
        var t = launched()
        XCTAssertEqual(t.state(now: s(0.1)), .preparing(nil))
        XCTAssertEqual(t.state(now: s(2.9)), .preparing(nil))
        t.picture(now: s(3))
        XCTAssertEqual(t.state(now: s(3.1)), .none)
    }

    func testPreparingAgainWhenAliveAndSilentForTwoSeconds() {
        var t = launched()
        t.picture(now: s(3))
        XCTAssertEqual(t.state(now: s(4.9)), .none)
        XCTAssertEqual(t.state(now: s(5.1)), .preparing(nil))
        t.picture(now: s(6))
        XCTAssertEqual(t.state(now: s(6.1)), .none, "a picture ends it")
    }

    func testTheNewestProgressIsShownWhileItIsUnderFiveSecondsOld() {
        var t = launched()
        t.picture(now: s(3))
        t.progress(p(1, 10, 100), now: s(6))
        XCTAssertEqual(t.state(now: s(8)), .preparing(p(1, 10, 100)))
        XCTAssertEqual(t.state(now: s(10.9)), .preparing(p(1, 10, 100)))
        XCTAssertEqual(t.state(now: s(11.1)), .preparing(nil), "no progress for 5 s: waiting")
    }

    func testAPausedGameIsNeverPreparing() {
        var t = launched()
        t.pausedChanged(true, now: s(1))
        XCTAssertEqual(t.state(now: s(2)), .none)
        t.progress(p(1, 1, 2), now: s(2))
        XCTAssertEqual(t.state(now: s(2.1)), .none, "progress for a paused game is not reported")
        t.pausedChanged(false, now: s(20))
        XCTAssertEqual(t.state(now: s(20.1)), .preparing(nil), "after the resume: still no picture, the old progress is stale")
    }

    func testResumingAGameThatHadPicturesWaitsTwoSecondsBeforePreparing() {
        var t = launched()
        t.picture(now: s(1))
        t.pausedChanged(true, now: s(2))
        t.pausedChanged(false, now: s(60))
        XCTAssertEqual(t.state(now: s(61)), .none, "the pause is not a silence")
        XCTAssertEqual(t.state(now: s(62.5)), .preparing(nil))
    }

    func testAPhaseRestartIsAllowedOnceAtAPhaseChange() {
        var t = launched()
        t.progress(p(1, 34649, 34649), now: s(1))
        XCTAssertEqual(t.state(now: s(1.1)), .preparing(p(1, 34649, 34649)))
        t.progress(p(2, 0, 900), now: s(2))
        XCTAssertEqual(t.state(now: s(2.1)), .preparing(p(2, 0, 900)))
    }

    func testDoneNeverGoesBackwardWithinAPhase() {
        var t = launched()
        t.progress(p(1, 500, 1000), now: s(1))
        t.progress(p(1, 200, 1000), now: s(1.5))
        XCTAssertEqual(t.state(now: s(1.6)), .preparing(p(1, 500, 1000)))
        t.progress(p(1, 700, 1000), now: s(2))
        XCTAssertEqual(t.state(now: s(2.1)), .preparing(p(1, 700, 1000)))
    }

    /// A "0 of 0" message inside a phase says "no count now"; it does not forget how far the phase had got.
    func testAZeroOfZeroMessageDoesNotLetDoneGoBackward() {
        var t = launched()
        t.progress(p(1, 500, 1000), now: s(1))
        t.progress(p(1, 0, 0), now: s(1.2))
        XCTAssertEqual(t.state(now: s(1.3)), .preparing(nil), "0 of 0 is waiting")
        t.progress(p(1, 200, 1000), now: s(1.5))
        XCTAssertEqual(t.state(now: s(1.6)), .preparing(p(1, 500, 1000)))
        t.progress(p(2, 100, 400), now: s(2))
        XCTAssertEqual(t.state(now: s(2.1)), .preparing(p(2, 100, 400)), "a new phase starts afresh")
    }

    func testDoneAboveTotalIsClamped() {
        var t = launched()
        t.progress(p(1, 1500, 1000), now: s(1))
        XCTAssertEqual(t.state(now: s(1.1)), .preparing(p(1, 1000, 1000)))
    }

    func testAZeroOfZeroPhaseShowsAsWaiting() {
        var t = launched()
        t.progress(p(2, 0, 0), now: s(1))
        XCTAssertEqual(t.state(now: s(1.1)), .preparing(nil))
    }

    func testAnUnknownPhaseShowsLikeAnyOther() {
        var t = launched()
        t.progress(p(7, 5, 50), now: s(1))
        XCTAssertEqual(t.state(now: s(1.1)), .preparing(p(7, 5, 50)))
    }

    func testAPictureForgetsTheProgress() {
        var t = launched()
        t.progress(p(1, 5, 50), now: s(1))
        t.picture(now: s(2))
        XCTAssertEqual(t.state(now: s(3.5)), .none)
        XCTAssertEqual(t.state(now: s(4.5)), .preparing(nil), "silence after a picture reports no progress from before it")
    }

    func testEndedGameIsNotPreparing() {
        var t = launched()
        t.ended()
        XCTAssertEqual(t.state(now: s(1)), .none)
    }
}
#endif
