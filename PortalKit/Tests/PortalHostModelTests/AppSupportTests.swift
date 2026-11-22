#if os(macOS)
import XCTest
import Foundation
import PortalHostCore
@testable import PortalHostModel

/// The pieces the Host app builds on that need no window -> .claude/host.md § app
final class AppSupportTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: device rows

    func testADeviceRowShowsItsKindsGlyphAndThePhoneBeforeItIsKnown() {
        XCTAssertEqual(DeviceGlyph.symbol(for: .phone), "iphone")
        XCTAssertEqual(DeviceGlyph.symbol(for: .tablet), "ipad")
        XCTAssertEqual(DeviceGlyph.symbol(for: .tv), "appletv")
        XCTAssertEqual(DeviceGlyph.symbol(for: nil), "iphone")
        XCTAssertFalse(DeviceGlyph.symbol(for: .tool).isEmpty)
    }

    // MARK: log lines

    func testLogLinesAreThoseOfTheHostDaemon() {
        func text(_ e: HostEvent, code: Bool = false) -> String { HostEventLine.text(e, showCode: code) }
        XCTAssertEqual(text(.listening(port: 5000)), "listening on port 5000")
        XCTAssertEqual(text(.status(.idle)), "status: idle")
        XCTAssertEqual(text(.status(.live(device: "Den iPad", tag: "1a2b3c4d", game: nil))), "status: live 1a2b3c4d")
        XCTAssertEqual(text(.status(.live(device: "Den iPad", tag: "1a2b3c4d", game: "Fake"))), "status: live 1a2b3c4d playing Fake")
        XCTAssertEqual(text(.status(.paused(game: "Fake"))), "status: paused Fake")
        XCTAssertEqual(text(.sessionEnd("session end: x")), "session end: x")
    }

    func testThePairingCodeIsInTheLineOnlyWhenAsked() {
        let s = HostStatus.pairing(code: "123456", until: Date())
        XCTAssertEqual(HostEventLine.text(.status(s), showCode: true), "status: pairing 123456")
        XCTAssertEqual(HostEventLine.text(.status(s), showCode: false), "status: pairing")
    }

    // MARK: log file

    func testLogFileAppendsOneLinePerCallWithATime() throws {
        let url = dir.appendingPathComponent("logs/host.log")
        let log = HostLogFile(url: url, clock: { Date(timeIntervalSince1970: 0) })
        log.write("status: idle")
        log.write("status: live Phone")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["1970-01-01T00:00:00Z status: idle", "1970-01-01T00:00:00Z status: live Phone"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLogFileRotatesOnceAtTheLimit() throws {
        let url = dir.appendingPathComponent("host.log")
        let older = dir.appendingPathComponent("host.log.1")
        let log = HostLogFile(url: url, limit: 200, clock: { Date(timeIntervalSince1970: 0) })
        for i in 0..<20 { log.write("line \(i) ................") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.path), "no rotated file")
        let size = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }
        XCTAssertLessThanOrEqual(size(url), 200)
        XCTAssertLessThanOrEqual(size(older), 200)
        let all = try String(contentsOf: older, encoding: .utf8) + String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(all.contains("line 19 "), "the newest line is lost")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("host.log.2").path))
    }

    func testARotationThatCannotMoveTheFileTruncatesIt() throws {
        let url = dir.appendingPathComponent("host.log")
        let older = dir.appendingPathComponent("host.log.1")
        try Data("old".utf8).write(to: older)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: older.path)  // it cannot be replaced
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: older.path) }
        let log = HostLogFile(url: url, limit: 200, clock: { Date(timeIntervalSince1970: 0) })
        for i in 0..<40 { log.write("line \(i) ................") }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, 200, "the log kept growing")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("line 39 "))
    }

    func testTheNoteEventIsTheLineItself() {
        XCTAssertEqual(HostEventLine.text(.note("T: did not exit after SIGKILL"), showCode: false), "T: did not exit after SIGKILL")
    }

    // MARK: environment file

    private func write(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("environment.json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEnvironmentFile() throws {
        XCTAssertEqual(EnvironmentFile.read(dir.appendingPathComponent("none.json")), .absent)
        XCTAssertEqual(EnvironmentFile.read(try write(#"{"HOME":"/x","FLAG":"1"}"#)), .variables(["HOME": "/x", "FLAG": "1"]))
        XCTAssertEqual(EnvironmentFile.read(try write("{}")), .variables([:]))
    }

    func testAnUnusableEnvironmentFileIsIgnoredWhole() throws {
        XCTAssertEqual(EnvironmentFile.read(try write("not json")), .ignored)
        XCTAssertEqual(EnvironmentFile.read(try write(#"["HOME"]"#)), .ignored)
        XCTAssertEqual(EnvironmentFile.read(try write(#"{"HOME":"/x","N":1}"#)), .ignored, "one wrong-typed value ignores the file")
        XCTAssertEqual(EnvironmentFile.read(dir), .ignored, "a folder is not a file")
    }

    // MARK: pairing notifications

    private actor Centre: NotificationCentring {
        let answer: Bool?  // nil: never answers
        private(set) var asked = 0
        private(set) var posted: [String] = []
        private(set) var removed = 0
        init(answer: Bool?) { self.answer = answer }
        func requestPermission() async -> Bool {
            asked += 1
            guard let answer else { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } ; return false }
            return answer
        }
        func post(id: String, title: String, body: String) { posted.append("\(title)|\(body)") }
        func remove(id: String) { removed += 1 }
        var summary: (asked: Int, posted: [String], removed: Int) { (asked, posted, removed) }
    }

    private func settle(_ centre: Centre, until cond: @escaping @Sendable ((asked: Int, posted: [String], removed: Int)) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if cond(await centre.summary) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    func testTheNotifierPostsTheCodeAndWithdrawsIt() async {
        let centre = Centre(answer: true)
        let notifier = PairingNotifier(centre: centre, title: "Code")
        await notifier.announce(code: "123456")
        let posted = await settle(centre) { $0.posted == ["Code|123456"] }
        XCTAssertTrue(posted)
        await notifier.announce(code: "654321")
        await notifier.withdraw()
        let done = await settle(centre) { $0.posted.count == 2 && $0.removed == 1 }
        let after = await centre.summary
        XCTAssertTrue(done, "\(after)")
        XCTAssertEqual(after.asked, 1, "the permission is asked once")
    }

    func testWithoutPermissionNothingIsPostedAndNothingFails() async {
        let centre = Centre(answer: false)
        let notifier = PairingNotifier(centre: centre, title: "Code")
        await notifier.announce(code: "123456")
        await notifier.announce(code: "654321")
        await notifier.withdraw()
        let asked = await settle(centre) { $0.asked == 1 }
        XCTAssertTrue(asked)
        try? await Task.sleep(nanoseconds: 100_000_000)  // the one fixed wait: proves that nothing is posted
        let s = await centre.summary
        XCTAssertEqual(s.posted, [])
        XCTAssertEqual(s.removed, 0)
        XCTAssertEqual(s.asked, 1)
    }

    /// A centre that never answers the permission question must not hold the calls: `announce` and `withdraw` return at once.
    func testAnnounceAndWithdrawReturnWhileThePermissionQuestionIsOpen() async {
        let centre = Centre(answer: nil)
        let notifier = PairingNotifier(centre: centre, title: "Code")
        let t0 = Date()
        await notifier.announce(code: "123456")
        await notifier.withdraw()
        await notifier.announce(code: "654321")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
    }
}
#endif
