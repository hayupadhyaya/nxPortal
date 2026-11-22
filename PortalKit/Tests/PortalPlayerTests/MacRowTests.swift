import XCTest
@testable import PortalPlayer

/// The Macs list's status words and dot per row (the view only draws them).
final class MacRowTests: XCTestCase {
    private func row(paired: Bool = true, reachable: Bool = true, current: Bool = false, playing: String? = nil) -> MacRow {
        MacRow(id: "a", name: "Den Mac", paired: paired, reachable: reachable, current: current, playing: playing)
    }

    func testEachRowSaysWhereItStands() {
        XCTAssertEqual(row(paired: false).status(state: .connected).text, "Pair")
        XCTAssertNil(row(paired: false).status(state: .connected).dot)
        XCTAssertEqual(row().status(state: .connected).text, "Found", "another Mac on the network")
        XCTAssertEqual(row(reachable: false).status(state: .connected).text, "Not found")
        let playing = row(current: true, playing: "Fake Game").status(state: .connected)
        XCTAssertEqual(playing.text, "Playing Fake Game")
        XCTAssertEqual(playing.dot, .positive)
        XCTAssertEqual(row(current: true).status(state: .connected).dot, .positive)
        XCTAssertEqual(row(current: true).status(state: .connecting).text, "Connecting…")
        XCTAssertEqual(row(current: true).status(state: .connecting).dot, .warning)
        XCTAssertEqual(row(current: true).status(state: .looking).text, "Looking…")
        XCTAssertEqual(row(current: true).status(state: .unreachable).text, "Not answering", "found, but no session")
        XCTAssertEqual(row(current: true).status(state: .unreachable).dot, .warning)
        XCTAssertEqual(row(reachable: false, current: true).status(state: .unreachable).text, "Not found")
        XCTAssertNil(row(reachable: false, current: true).status(state: .unreachable).dot)
    }

    func testTheCurrentMacSaysSoToVoiceOver() {
        XCTAssertEqual(row(current: true).accessibilityValue(state: .connected), "Connected, current")
        XCTAssertEqual(row().accessibilityValue(state: .connected), "Found")
    }
}
