#if os(macOS)
import XCTest
@testable import PortalHostCore

/// A listener's stop returns when the port is really free: a new one binds the same pinned port at once.
final class ControlListenerRestartTests: XCTestCase {
    func testAListenerStoppedAndRestartedOnItsPortBindsEveryTime() async throws {
        for round in 0..<20 {
            let first = ControlListener()
            let port = try await first.start(port: 0, serviceName: nil)
            await first.stopAndWait()
            let second = ControlListener()
            do {
                let again = try await second.start(port: port, serviceName: nil)
                XCTAssertEqual(again, port, "round \(round)")
            } catch {
                XCTFail("round \(round): the same port did not bind after a stop: \(error)")
            }
            await second.stopAndWait()
        }
    }

    func testStopAndWaitOnAListenerThatNeverStartedReturns() async {
        await ControlListener().stopAndWait()
    }
}
#endif
