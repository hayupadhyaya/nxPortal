import XCTest
import PortalKit

/// The one rule for "preparing N %", shown by the device's tile and starting card and by the Mac's menu.
final class PreparingTests: XCTestCase {
    private func p(_ done: UInt32, _ total: UInt32) -> Preparing { Preparing(phase: 2, done: done, total: total) }

    func testTheFractionAndPercent() {
        XCTAssertEqual(p(12_400, 34_649).fraction, 0.358, accuracy: 0.001)
        XCTAssertEqual(p(12_400, 34_649).percent, 36)
        XCTAssertEqual(p(1500, 1000).fraction, 1, "never above the whole")
        XCTAssertEqual(Preparing.waiting.fraction, 0)
        XCTAssertEqual(Preparing.waiting.percent, 0)
    }

    /// Rounded, held at 99 until done: 3 of 8 is 38 (37.5 rounded), not 37.
    func testThePercentIsRoundedAndHeldAt99UntilDone() {
        XCTAssertEqual(p(3, 8).percent, 38)
        XCTAssertEqual(p(9_990, 10_000).percent, 99, "100 only when it is done")
        XCTAssertEqual(p(10_000, 10_000).percent, 100)
        XCTAssertEqual(p(5000, 1000).percent, 100, "never past 100")
    }
}
