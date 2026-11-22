import XCTest
@testable import PortalKit

/// The model's short name, from the hardware identifier -> .claude/portalkit.md § wire-network
final class DeviceModelNameTests: XCTestCase {
    func testKnownIdentifiers() {
        XCTAssertEqual(DeviceModelName.name(machine: "iPad14,1"), "iPad mini")
        XCTAssertEqual(DeviceModelName.name(machine: "AppleTV14,1"), "Apple TV 4K")
        XCTAssertEqual(DeviceModelName.name(machine: "iPhone17,1"), "iPhone 16 Pro")
        XCTAssertEqual(DeviceModelName.name(machine: "iPad16,5"), "iPad Pro 13-inch")
    }

    func testAnUnknownIdentifierGivesItsFamily() {
        XCTAssertEqual(DeviceModelName.name(machine: "iPad99,9"), "iPad")
        XCTAssertEqual(DeviceModelName.name(machine: "iPhone99,1"), "iPhone")
        XCTAssertEqual(DeviceModelName.name(machine: "AppleTV99,1"), "Apple TV")
        XCTAssertEqual(DeviceModelName.name(machine: "Mac15,3"), "Device")
        XCTAssertEqual(DeviceModelName.name(machine: ""), "Device")
    }

    func testTheSimulatorsIdentifierIsRead() {
        XCTAssertEqual(DeviceModelName.current(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPad14,1"]), "iPad mini")
        XCTAssertEqual(DeviceModelName.machineIdentifier(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPad14,1"]), "iPad14,1")
        XCTAssertFalse(DeviceModelName.current(environment: [:]).isEmpty, "uname gives something on this Mac")
    }

    func testEveryTableValueIsUsable() {
        XCTAssertFalse(DeviceModelName.table.isEmpty)
        for (id, name) in DeviceModelName.table {
            XCTAssertFalse(name.isEmpty, id)
            XCTAssertLessThanOrEqual(name.count, DeviceName.maxCharacters, id)
            XCTAssertEqual(DeviceName.clean(name), name, "\(id): a table name is already clean")
        }
    }
}
