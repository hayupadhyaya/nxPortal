import XCTest
@testable import PortalKit

final class VersionsTests: XCTestCase {
    func testVersions() {
        XCTAssertEqual(ProtocolVersion.tap, 2)
        XCTAssertEqual(ProtocolVersion.network, 4)
    }
}
