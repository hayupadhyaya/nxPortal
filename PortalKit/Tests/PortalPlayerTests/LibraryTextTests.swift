import XCTest
import PortalKit
@testable import PortalPlayer

final class LibraryTextTests: XCTestCase {
    private func game(_ name: String, streamable: Bool = true, state: GameRunState = .idle) -> GameEntry {
        GameEntry(titleID: "FAKE000000000000", name: name, streamable: streamable, state: state)
    }

    /// First run's "Still looking" note: from 30 s of looking, never before, never with no search.
    func testStillLookingShowsFromThirtySeconds() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(LibraryText.showsStillLooking(since: nil, now: t0.addingTimeInterval(100)))
        XCTAssertFalse(LibraryText.showsStillLooking(since: t0, now: t0.addingTimeInterval(29.9)))
        XCTAssertTrue(LibraryText.showsStillLooking(since: t0, now: t0.addingTimeInterval(30)))
    }

    func testInitialsAreTheFirstLettersOfTheFirstTwoWords() {
        XCTAssertEqual(LibraryText.initials("Moon Maker"), "MM")
        XCTAssertEqual(LibraryText.initials("orbit nine and more"), "ON")
        XCTAssertEqual(LibraryText.initials("Lantern"), "L")
        XCTAssertEqual(LibraryText.initials("  "), "")
    }

    func testTileStates() {
        XCTAssertEqual(LibraryText.tileState(game("A"), reachable: true), .normal)
        XCTAssertEqual(LibraryText.tileState(game("A", state: .paused), reachable: true), .paused)
        XCTAssertEqual(LibraryText.tileState(game("A", streamable: false), reachable: true), .rebuild)
        XCTAssertEqual(LibraryText.tileState(game("A", streamable: false), reachable: false), .unreachable)
    }

    func testVoiceOverValuesAndHint() {
        XCTAssertEqual(LibraryText.tileValue(.paused), "Paused")
        XCTAssertEqual(LibraryText.tileValue(.rebuild), "Needs a rebuild on the Mac")
        XCTAssertEqual(LibraryText.tileValue(.unreachable), "Mac not reachable")
        XCTAssertEqual(LibraryText.tileValue(.normal), "")
        XCTAssertEqual(LibraryText.tileHint, "Plays the game.")
    }

    func testContinueCardText() {
        XCTAssertEqual(LibraryText.continueState(game("A", state: .paused)), "Paused")
        XCTAssertEqual(LibraryText.continueState(game("A", state: .running)), "Playing")
        XCTAssertEqual(LibraryText.continueState(game("A")), "Last played here")
        let p = Preparing(phase: 1, done: 360, total: 1000)
        XCTAssertEqual(LibraryText.continueState(game("A", state: .running), preparing: p), "Preparing 36 %", "a live library shows the progress")
        XCTAssertEqual(LibraryText.continueState(game("A", state: .running), preparing: .waiting), "Preparing")
        XCTAssertEqual(LibraryText.continueState(game("A", state: .paused), preparing: p), "Paused")
        // A library session (the game does not play here) never reads "Playing": starting, or a pause still owed.
        XCTAssertEqual(LibraryText.continueState(game("A", state: .starting), playsHere: false), "Starting")
        XCTAssertEqual(LibraryText.continueState(game("A", state: .starting), playsHere: true), "Starting")
        XCTAssertEqual(LibraryText.continueState(game("A", state: .running), playsHere: false), "Preparing")
        XCTAssertEqual(LibraryText.continueState(game("A", state: .running), playsHere: true), "Playing")
        XCTAssertEqual(LibraryText.continueLabel(game("Moon Maker", state: .starting), playsHere: false), "Continue, Moon Maker, starting")
        XCTAssertEqual(LibraryText.continueLabel(game("Moon Maker", state: .paused)), "Continue, Moon Maker, paused")
        XCTAssertEqual(LibraryText.continueAction(game("A", state: .paused)), "Resume")
        XCTAssertEqual(LibraryText.continueAction(game("A")), "Play")
    }

    func testEmptyLibrary() {
        XCTAssertEqual(LibraryText.empty(mac: "Test Mac"),
                       "No games on Test Mac yet. Games that support streaming show up here when they are in the Mac's game folders.")
    }

    func testTheLibraryIsLoadingBetweenConnectedAndTheFirstList() {
        XCTAssertTrue(LibraryText.showsLoading(connected: true, listed: false, games: 0))
        XCTAssertFalse(LibraryText.showsLoading(connected: true, listed: true, games: 0), "a list that came empty is really empty")
        XCTAssertFalse(LibraryText.showsLoading(connected: true, listed: false, games: 3), "cached games show at once")
        XCTAssertFalse(LibraryText.showsLoading(connected: false, listed: false, games: 0), "not connected: the banner says why")
        XCTAssertFalse(LibraryText.showsLoading(connected: true, listed: false, games: 0, failed: true), "a failed list is not loading")
        XCTAssertTrue(LibraryText.showsCouldNotLoad(connected: true, listed: false, games: 0, failed: true))
        XCTAssertFalse(LibraryText.showsCouldNotLoad(connected: true, listed: false, games: 0, failed: false))
        XCTAssertFalse(LibraryText.showsCouldNotLoad(connected: true, listed: true, games: 0, failed: true), "a list came since")
        XCTAssertFalse(LibraryText.showsCouldNotLoad(connected: true, listed: false, games: 2, failed: true), "cached games show")
        XCTAssertEqual(LibraryText.couldNotLoad(mac: "Test Mac"), "Could not load the games on Test Mac.")
        XCTAssertEqual(LibraryText.loading, "Loading games\u{2026}")
    }

    func testTheAppleTvFocusCaption() {
        XCTAssertEqual(LibraryText.focusedLabel, "Focused")
        XCTAssertEqual(LibraryText.focusHint, "Press and hold for options")
        XCTAssertEqual(LibraryText.focusState(.normal, lastPlayed: true), "Last played here")
        XCTAssertNil(LibraryText.focusState(.normal, lastPlayed: false), "a plain game has nothing to add")
        XCTAssertEqual(LibraryText.focusState(.paused, lastPlayed: true), "Paused")
        XCTAssertEqual(LibraryText.focusState(.rebuild, lastPlayed: false), LibraryText.tileValue(.rebuild))
        XCTAssertEqual(LibraryText.focusState(.unreachable, lastPlayed: true), "Mac not reachable")
        XCTAssertEqual(LibraryText.focusState(.preparing(percent: 36), lastPlayed: false), "Preparing, 36 percent")
    }
}
