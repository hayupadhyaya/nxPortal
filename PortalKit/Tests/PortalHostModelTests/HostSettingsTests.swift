#if os(macOS)
import XCTest
import Foundation
import PortalHostCore
@testable import PortalHostModel

final class HostSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "nxp-settings-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaults() {
        let settings = HostSettingsStore(defaults: defaults).load()
        XCTAssertNil(settings.name, "nil = the computer's name")
        XCTAssertEqual(settings.folders, [])
        XCTAssertEqual(settings.maxBitrate, HostDefaults.maxBitrate)
    }

    func testRoundTrip() {
        let store = HostSettingsStore(defaults: defaults)
        let settings = HostSettings(name: "Den", folders: [URL(fileURLWithPath: "/tmp/nxp-games")], maxBitrate: 80_000_000)
        store.save(settings)
        XCTAssertEqual(HostSettingsStore(defaults: defaults).load(), settings)
    }

    func testCorruptDataGivesTheDefaults() {
        defaults.set(Data("not json".utf8), forKey: "hostSettings")
        XCTAssertEqual(HostSettingsStore(defaults: defaults).load(), HostSettings())
        defaults.set("a string, not data", forKey: "hostSettings")
        XCTAssertEqual(HostSettingsStore(defaults: defaults).load(), HostSettings())
    }

    func testStoredDataWithOnlyTheNameKeepsIt() {
        defaults.set(Data(#"{"name":"Den"}"#.utf8), forKey: "hostSettings")
        let settings = HostSettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.name, "Den")
        XCTAssertEqual(settings.folders, [])
        XCTAssertEqual(settings.maxBitrate, HostDefaults.maxBitrate)
        defaults.set(Data(#"{"folders":["file:///tmp/nxp-games"]}"#.utf8), forKey: "hostSettings")
        XCTAssertEqual(HostSettingsStore(defaults: defaults).load().folders, [URL(string: "file:///tmp/nxp-games")!])
    }

    func testTheKeyIsHostSettings() {
        HostSettingsStore(defaults: defaults).save(HostSettings(name: "Den"))
        XCTAssertNotNil(defaults.data(forKey: "hostSettings"))
    }
}
#endif
