import XCTest
import PortalKit
@testable import PortalPlayer

/// The value lists the app's setting pickers offer live in PortalPlayer; the views only name them.
final class SettingsChoicesTests: XCTestCase {
    func testTheListsAreTheOnesTheDocsName() {
        XCTAssertEqual(SettingsChoices.sizes, [SettingsChoices.Size(width: 1280, height: 720), .init(width: 1920, height: 1080),
                                               .init(width: 2560, height: 1440)])
        XCTAssertEqual(SettingsChoices.rates, [30, 60])
        XCTAssertEqual(SettingsChoices.bitrates, [10, 20, 30, 50, 80, 100, 150, 200])
        XCTAssertEqual(SettingsChoices.buffers, [10, 25, 50, 75, 100])
        XCTAssertEqual(PanelLevel.allCases.map(PanelText.name), ["Off", "FPS", "Compact", "Full"])
    }

    func testTheDefaultsAreInTheirLists() {
        let s = ClientSettings()
        XCTAssertTrue(SettingsChoices.sizes.contains(.init(width: s.maxWidth, height: s.maxHeight)))
        XCTAssertTrue(SettingsChoices.rates.contains(s.maxFps))
        XCTAssertTrue(SettingsChoices.bitrates.contains(s.bitrateMbps))
        XCTAssertTrue(SettingsChoices.buffers.contains(s.audioBufferMs))
    }

    func testASavedValueOutsideTheListGetsItsOwnEntry() {
        XCTAssertEqual(SettingsChoices.list([10, 20], current: 20), [10, 20])
        XCTAssertEqual(SettingsChoices.list([10, 20], current: 15), [10, 20, 15])
        var s = ClientSettings(); s.bitrateMbps = 70; s.maxFps = 45; s.maxWidth = 1000; s.maxHeight = 600
        XCTAssertEqual(SettingsChoices.bitrates(for: s).last, 70)
        XCTAssertEqual(SettingsChoices.rates(for: s).last, 45)
        XCTAssertEqual(SettingsChoices.sizes(for: s).last, .init(width: 1000, height: 600))
        XCTAssertEqual(SettingsChoices.sizes(for: ClientSettings()).count, 3)
    }
}
