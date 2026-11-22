#if os(macOS)
import XCTest
import Foundation
@testable import PortalHostCore

final class GameLibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-l-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func makeBundle(_ relative: String, plist: [String: Any]) throws {
        let contents = root.appendingPathComponent(relative).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testScan() throws {
        try makeBundle("Streams.app", plist: ["DMTitleID": "0000000000000001", "DMStream": true,
                                              "CFBundleDisplayName": "Beta"])
        try makeBundle("Sub/Plain.app", plist: ["DMTitleID": "0000000000000002", "CFBundleName": "Alpha"])
        try makeBundle("Other.app", plist: ["CFBundleName": "Not a game"])

        let apps = GameLibrary(roots: [root]).scan()
        XCTAssertEqual(apps.map(\.titleID), ["0000000000000002", "0000000000000001"], "sorted by name")
        XCTAssertEqual(apps.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(apps.map(\.streamable), [false, true])
        XCTAssertEqual(apps[1].url.lastPathComponent, "Streams.app")
    }

    /// The bundle ID (the preferences domain of the app's saved choices) is the app's own `CFBundleIdentifier`; absent stays nil.
    func testTheBundleIDIsTheAppsOwn() throws {
        try makeBundle("With.app", plist: ["DMTitleID": "0000000000000001", "CFBundleName": "A", "CFBundleIdentifier": "test.nxportal.library.a"])
        try makeBundle("Without.app", plist: ["DMTitleID": "0000000000000002", "CFBundleName": "B"])
        try makeBundle("Odd.app", plist: ["DMTitleID": "0000000000000003", "CFBundleName": "C", "CFBundleIdentifier": 7])
        let apps = Dictionary(uniqueKeysWithValues: GameLibrary(roots: [root]).scan().map { ($0.titleID, $0.bundleID) })
        XCTAssertEqual(apps["0000000000000001"] ?? nil, "test.nxportal.library.a")
        XCTAssertNil(apps["0000000000000002"] ?? nil)
        XCTAssertNil(apps["0000000000000003"] ?? nil, "an identifier that is not text is none")
    }

    /// The same game in two folders is one entry: the first copy that can stream, wherever it sits; else the first found.
    func testOneEntryPerGameACopyThatStreamsWins() throws {
        try makeBundle("apps/Game.app", plist: ["DMTitleID": "0000000000000001", "CFBundleName": "Game"])
        try makeBundle("mine/Game.app", plist: ["DMTitleID": "0000000000000001", "DMStream": true, "CFBundleName": "Game"])
        try makeBundle("later/Game.app", plist: ["DMTitleID": "0000000000000001", "DMStream": true, "CFBundleName": "Game"])
        try makeBundle("apps/Plain.app", plist: ["DMTitleID": "0000000000000002", "CFBundleName": "Plain"])
        try makeBundle("mine/Plain.app", plist: ["DMTitleID": "0000000000000002", "CFBundleName": "Plain"])

        let roots = ["apps", "mine", "later"].map { root.appendingPathComponent($0) }
        let apps = GameLibrary(roots: roots).scan()
        XCTAssertEqual(apps.map(\.titleID), ["0000000000000001", "0000000000000002"], "one entry per game")
        XCTAssertEqual(apps.map(\.streamable), [true, false])
        XCTAssertEqual(apps[0].url.deletingLastPathComponent().lastPathComponent, "mine", "the first copy that can stream")
        XCTAssertEqual(apps[1].url.deletingLastPathComponent().lastPathComponent, "apps", "the first found")
    }

    /// A root that is missing or unreadable contributes nothing and is no error; the other roots are listed.
    func testUnreadableRootIsSkipped() throws {
        try makeBundle("Streams.app", plist: ["DMTitleID": "0000000000000001", "CFBundleName": "Alpha"])
        let locked = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-l-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer { chmod(locked.path, 0o700); try? FileManager.default.removeItem(at: locked) }
        let hidden = locked.appendingPathComponent("Hidden.app/Contents")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        chmod(locked.path, 0o000)
        let missing = root.appendingPathComponent("does-not-exist")
        let apps = GameLibrary(roots: [missing, locked, root]).scan()
        XCTAssertEqual(apps.map(\.titleID), ["0000000000000001"])
        XCTAssertTrue(GameLibrary(roots: [missing, locked]).scan().isEmpty)
    }
}
#endif
