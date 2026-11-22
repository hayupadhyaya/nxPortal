import XCTest
@testable import PortalPlayer

final class TouchTextTests: XCTestCase {
    func testTheWordsAPersonSees() {
        XCTAssertEqual(TouchText.groupTitle, "On-screen controls")
        XCTAssertEqual(TouchText.layoutTitle, "Touch layout")
        XCTAssertEqual(TouchText.layoutForNewGames, "Layout for new games")
        XCTAssertEqual(TouchText.hapticsTitle, "Haptics on touch controls")
        XCTAssertEqual(TouchText.acknowledgements, "Acknowledgements")
        XCTAssertEqual(TouchText.controllerConnected, "Controller connected \u{00B7} touch controls hidden")
        XCTAssertEqual(TouchText.connectController, "Connect a controller to play.")
        XCTAssertEqual(TouchText.menuButton, "Menu")
        XCTAssertEqual(TouchText.name(.flat), "Simple (2D)")
        XCTAssertEqual(TouchText.name(.full), "Full (3D)")
        XCTAssertEqual(TouchLayout.allCases.map(TouchText.name).count, 2)
    }

    func testNoSentenceNamesAGameOrAnotherProduct() {
        let all = [TouchText.layoutNote, TouchText.hapticsNote, TouchText.layoutTitle, TouchText.padName]
        for s in all { XCTAssertFalse(s.isEmpty); XCTAssertFalse(s.contains("  ")) }
    }

    func testTheChoicesAreBothLayoutsInOrder() {
        XCTAssertEqual(TouchText.choices.map(\.0), [.flat, .full])
        XCTAssertEqual(TouchText.choices.map(\.1), ["Simple (2D)", "Full (3D)"])
    }

    func testTheLayoutRowShowsOnlyWithNoGameController() {
        XCTAssertTrue(TouchText.showsLayoutRow(gameControllers: 0))
        XCTAssertFalse(TouchText.showsLayoutRow(gameControllers: 1))
        XCTAssertFalse(TouchText.showsLayoutRow(gameControllers: 3))
    }
}
