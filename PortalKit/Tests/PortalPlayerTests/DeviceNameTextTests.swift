import XCTest
import PortalKit
@testable import PortalPlayer

final class DeviceNameTextTests: XCTestCase {
    func testTheSentences() {
        XCTAssertEqual(DeviceNameText.title, "This device's name")
        XCTAssertEqual(DeviceNameText.footer, "Macs on your network show this name. A Mac that renamed this device keeps its own name.")
        XCTAssertEqual(DeviceNameText.placeholder(), DeviceModelName.current())
        XCTAssertFalse(DeviceNameText.placeholder().isEmpty)
    }

    /// The row's text (label, field, the placeholder and the note, both secondary) on the glass the group is drawn on.
    func testTheRowsTextOnTheGroupsGlass() {
        for palette in [LookTokens.dark, LookTokens.light] {
            let glass = palette.glass.over(palette.background)
            for (name, c) in [("text", palette.text), ("secondary", palette.secondaryText)] {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(c, glass), 4.5, name)
            }
        }
    }
}
