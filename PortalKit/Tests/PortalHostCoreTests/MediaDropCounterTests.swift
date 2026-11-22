#if os(macOS)
import XCTest
@testable import PortalHostCore

final class MediaDropCounterTests: XCTestCase {
    private let sec: UInt64 = 1_000_000_000

    func testNothingToReportWithoutDrops() {
        var c = MediaDropCounter()
        XCTAssertNil(c.reportDue(nowNs: 5 * sec))
        XCTAssertNil(c.reportDue(nowNs: 9 * sec))
    }

    func testOneReportASecondWithTheCount() {
        var c = MediaDropCounter()
        XCTAssertNil(c.reportDue(nowNs: 10 * sec))  // starts the clock
        c.dropped(); c.dropped(); c.dropped()
        XCTAssertNil(c.reportDue(nowNs: 10 * sec + sec / 2), "less than a second since the last report")
        XCTAssertEqual(c.reportDue(nowNs: 11 * sec), 3)
        XCTAssertNil(c.reportDue(nowNs: 11 * sec + 1), "counted and reset")
        c.dropped()
        XCTAssertNil(c.reportDue(nowNs: 11 * sec + sec / 2))
        XCTAssertEqual(c.reportDue(nowNs: 12 * sec + 1), 1)
    }
}
#endif
