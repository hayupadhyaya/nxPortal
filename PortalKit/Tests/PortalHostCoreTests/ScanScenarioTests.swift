#if os(macOS)
import XCTest
@testable import PortalHostCore
import PortalTestSupport

/// A library scan during play -> .claude/host.md § library
final class ScanScenarioTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()  // guards value
        private var value: Int?
        func set(_ n: Int) { lock.withLock { value = n } }
        var count: Int? { lock.withLock { value } }
    }

    /// 6,000 app folders under the library root and a `listRequest` in the middle of a stream: the list arrives with all of
    /// them, and the media never waits for the scan (the longest gap between frames out stays under 100 ms).
    func testScanDoesNotBlockMedia() async throws {
        let apps = 6000  // the brief says 2,000; on a warm cache that scan takes 60-80 ms here, too close to the 100 ms rule to tell the cases apart
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-sc-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)))
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<apps {
            let contents = root.appendingPathComponent("Game \(i).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["DMTitleID": String(format: "%016x", i + 1), "CFBundleName": "Game \(i)"], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let listed = Box()
        let r = try await StreamScenario.run(profile: .clean, seconds: 6, sessionMidway: { s in
            Task { if let entries = try? await s.list() { listed.set(entries.count) } }
        }, configure: { $0.libraryRoots = [root] })
        print(r.line("scan"))
        XCTAssertTrue(r.alive)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(listed.count, apps + 1, "\(apps) apps and the fake game")
        XCTAssertLessThan(r.longestGapMs, 100, "media waited \(r.longestGapMs) ms")
    }
}
#endif
