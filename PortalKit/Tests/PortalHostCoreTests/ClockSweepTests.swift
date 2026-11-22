#if os(macOS)
import XCTest
import Foundation

/// Session timers read the injected clock, never `Date()` -> .claude/host.md § service
final class ClockSweepTests: XCTestCase {
    /// Every spelling of the wall clock: `Date()`, `Date.now`, a bare `.now` (`let d: Date = .now`; `self.now()` is the
    /// Host's own helper and has an identifier before the dot), `Date(timeIntervalSinceNow:)`, `CFAbsoluteTimeGetCurrent`.
    private static let wallClock = #"\bDate\(\)|\bDate\.now\b|(?<![A-Za-z0-9_)\]])\.now\b(?!\()|\bDate\(timeIntervalSinceNow|CFAbsoluteTimeGetCurrent"#

    /// The only `Date()` allowed in `PortalHostCore` is the pairing window (a display and security window on wall time) and the
    /// date a pairing is stored with (`PairingStore.wallClock`), each marked `wall time:` on its own line.
    func testNoWallClockOutsideThePairingWindow() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PortalHostCore")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "the sources were not found at \(sources.path)")
        var offenders: [String] = []
        var marked = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line  // a comment may name them
                guard code.range(of: Self.wallClock, options: .regularExpression) != nil else { continue }
                if line.contains("// wall time:") { marked += 1; continue }
                offenders.append("\(file.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "wall clock outside the clock helper and the pairing window")
        XCTAssertEqual(marked, 4, "the wall-time sites changed: the pairing window's begin, verify, expiry and the stored pairing date")
    }
}
#endif
