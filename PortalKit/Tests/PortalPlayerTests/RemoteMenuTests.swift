import XCTest
@testable import PortalPlayer

final class RemoteMenuTests: XCTestCase {
    func testMenuOpensTheMenuWhenItMayAndLeavesWhenItMayNot() {
        var r = RemoteMenuRule()
        XCTAssertEqual(r.press(.menu, menuOpen: false, allowed: true, at: 1), .open)
        XCTAssertEqual(r.press(.menu, menuOpen: false, allowed: false, at: 2), .leave, "over the ended card Menu is Back to games")
    }

    func testMenuClosesAnOpenMenuAndNeverLeaves() {
        var r = RemoteMenuRule()
        XCTAssertEqual(r.press(.menu, menuOpen: true, allowed: true, at: 1), .close)
        XCTAssertEqual(r.press(.menu, menuOpen: true, allowed: false, at: 2), .close, "open is open, whatever `allowed` says")
    }

    func testPlayPauseOpensButNeverClosesOrLeaves() {
        var r = RemoteMenuRule()
        XCTAssertEqual(r.press(.playPause, menuOpen: false, allowed: true, at: 1), .open)
        XCTAssertEqual(r.press(.playPause, menuOpen: true, allowed: true, at: 2), .ignore, "on a focused button it is the system's")
        XCTAssertEqual(r.press(.playPause, menuOpen: false, allowed: false, at: 3), .ignore)
    }

    /// B closes the menu through `ControllerInput.onBack`; the system's Menu press that B also makes must not reopen it.
    func testTheMenuPressThatFollowsAControllersBIsTheSamePress() {
        var r = RemoteMenuRule()
        r.controllerBack(at: 10)
        XCTAssertEqual(r.press(.menu, menuOpen: false, allowed: true, at: 10.1), .ignore)
        XCTAssertEqual(r.press(.menu, menuOpen: true, allowed: true, at: 10.2), .ignore, "nor close what is already closing")
        XCTAssertEqual(r.press(.menu, menuOpen: false, allowed: true, at: 10 + RemoteMenuRule.backWindow + 0.01), .open,
                       "a later press is the person's")
    }

    func testAPressBeforeAnyBIsNotHeldBack() {
        var r = RemoteMenuRule()
        XCTAssertEqual(r.press(.menu, menuOpen: false, allowed: true, at: 0.1), .open)
    }
}
