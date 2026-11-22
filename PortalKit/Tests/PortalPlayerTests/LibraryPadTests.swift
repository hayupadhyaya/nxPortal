import XCTest
@testable import PortalPlayer

@MainActor
final class LibraryPadTests: XCTestCase {
    private func make() -> (LibraryPad, () -> [String]) {
        let pad = LibraryPad()
        var opened: [String] = []
        pad.onOptions = { opened.append($0) }
        return (pad, { opened })
    }

    func testYOnTheFocusedTileOpensItsPageOnce() {
        let (pad, opened) = make()
        pad.focused = "TITLE1"
        pad.yChanged(true)
        pad.yChanged(true)  // held: no repeat
        XCTAssertEqual(opened(), ["TITLE1"])
        pad.yChanged(false)
        pad.focused = "TITLE2"
        pad.yChanged(true)
        XCTAssertEqual(opened(), ["TITLE1", "TITLE2"])
    }

    func testYWithNoFocusedTileOrOnReleaseDoesNothing() {
        let (pad, opened) = make()
        pad.yChanged(true)
        pad.yChanged(false)
        pad.focused = "TITLE1"
        pad.yChanged(false)
        XCTAssertEqual(opened(), [])
    }

    /// Anything presented over the library (a sheet, the page, the game) is `frontmost == false`.
    func testYWhileSomethingIsOverTheLibraryOpensNothingAndClosingDoesNotFireAHeldY() {
        let (pad, opened) = make()
        pad.focused = "TITLE1"
        pad.frontmost = false
        pad.yChanged(true)
        pad.yChanged(false)
        XCTAssertEqual(opened(), [])
        pad.yChanged(true)  // held while the sheet closes
        pad.frontmost = true
        pad.yChanged(true)
        XCTAssertEqual(opened(), [], "a Y held across the sheet's closing counted as a new press")
        pad.yChanged(false)
        pad.yChanged(true)
        pad.yChanged(true)
        XCTAssertEqual(opened(), ["TITLE1"], "one press opens once")
    }

    /// The held state is per controller and goes with the controller.
    func testAControllerThatDisconnectsHoldingYDoesNotBlockTheNextOne() {
        let (pad, opened) = make()
        let padA = NSObject(), padB = NSObject(), padC = NSObject()  // alive, so the identities differ
        let a = ObjectIdentifier(padA), b = ObjectIdentifier(padB)
        pad.focused = "TITLE1"
        pad.yChanged(true, from: a)
        XCTAssertEqual(opened(), ["TITLE1"])
        pad.yChanged(true, from: b)  // a second pad's own press, a still holding
        XCTAssertEqual(opened(), ["TITLE1", "TITLE1"])
        pad.controllerGone(a)  // disconnected mid-hold
        pad.yChanged(true, from: ObjectIdentifier(padC))
        XCTAssertEqual(opened().count, 3, "a new controller's first press was lost")
    }
}
