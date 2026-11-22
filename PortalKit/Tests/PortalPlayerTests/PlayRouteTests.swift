import XCTest
@testable import PortalPlayer

final class PlayRouteTests: XCTestCase {
    private func covered(_ o: PlayOverlays, _ trouble: TroubleStage = .none, starting: Bool = false) -> Bool {
        o.covers(trouble: trouble, startingCard: starting)
    }

    func testPlayingGivesTheControllerToTheGameOnly() {
        XCTAssertEqual(PlayRoute.controller(menuOpen: false, trouble: .none, startingCard: false, sheet: false), .game)
        XCTAssertEqual(PlayRoute.controller(menuOpen: false, trouble: .pill, startingCard: false, sheet: false), .game,
                       "the pill has no buttons: the game keeps playing")
    }

    /// Each cover alone covers the picture: the menu, a sheet over play, the reconnecting and ended cards, the starting card.
    func testEveryCoverAloneCoversThePicture() {
        XCTAssertEqual(PlayRoute.controller(menuOpen: true, trouble: .none, startingCard: false, sheet: false), .focus)
        XCTAssertEqual(PlayRoute.controller(menuOpen: false, trouble: .none, startingCard: false, sheet: true), .focus,
                       "a sheet over play is a cover")
        XCTAssertEqual(PlayRoute.controller(menuOpen: false, trouble: .reconnecting, startingCard: false, sheet: false), .focus)
        XCTAssertEqual(PlayRoute.controller(menuOpen: false, trouble: .ended(reason: "x"), startingCard: false, sheet: false), .focus)
        XCTAssertEqual(PlayRoute.controller(menuOpen: false, trouble: .none, startingCard: true, sheet: false), .focus)
    }

    /// The play states in the order a person meets them: the picture is covered from the menu's opening until the last thing
    /// over it has closed, and the close routes close the top thing only.
    func testWalkingThePlayStatesTheCoverHoldsUntilNothingIsOverThePicture() {
        var o = PlayOverlays()
        XCTAssertTrue(covered(o, starting: true), "the starting card")
        XCTAssertFalse(covered(o), "the game plays")
        XCTAssertFalse(covered(o, .pill), "the pill")
        XCTAssertTrue(o.toggle(allowed: true))
        XCTAssertTrue(o.menu)
        XCTAssertTrue(covered(o), "the menu")
        o.sheet = true  // "All game options"
        XCTAssertTrue(covered(o), "the sheet over the menu")
        o.back()
        XCTAssertEqual(o, PlayOverlays(menu: true, sheet: false), "B closes the sheet, not the menu under it")
        XCTAssertTrue(covered(o), "the menu is still up")
        o.back()
        XCTAssertFalse(covered(o), "B again: nothing covers")
        o = PlayOverlays(menu: true, sheet: true)
        o.toggle(allowed: true)
        XCTAssertEqual(o, PlayOverlays(menu: true, sheet: false), "Home / the chord close the sheet only")
        o.toggle(allowed: true)
        XCTAssertFalse(covered(o))
        XCTAssertTrue(covered(o, .reconnecting), "the reconnecting card")
        XCTAssertFalse(o.toggle(allowed: false), "no menu over a card")
        XCTAssertTrue(covered(o, .ended(reason: "x")), "the ended card")
    }
}
