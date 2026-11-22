#if os(macOS)
import XCTest
@testable import PortalHostCore

/// What a person reads when a Host call fails: one sentence per case, no identifiers -> .claude/host.md § service
final class HostServiceErrorTests: XCTestCase {
    func testSystemErrorReadsAsOneSentenceWithoutItsDetails() {
        let text = HostServiceError.system("bind", 48).localizedDescription
        XCTAssertEqual(text, "The Host could not set up its network connection.")
        XCTAssertFalse(text.contains("bind") || text.contains("48"), "the call name or errno leaked: \(text)")
    }

    func testAlreadyStartedReadsAsOneSentence() {
        XCTAssertEqual(HostServiceError.alreadyStarted.localizedDescription, "The Host is already running.")
    }

    func testStoppedReadsAsOneSentence() {
        XCTAssertEqual(HostServiceError.stopped.localizedDescription, "The Host is not running.")
    }
}
#endif
