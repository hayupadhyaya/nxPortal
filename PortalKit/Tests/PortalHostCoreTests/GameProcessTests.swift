#if os(macOS)
import XCTest
import Foundation
@testable import PortalHostCore

final class GameProcessTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-g-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// `<root>/T.app` whose `nxnative` is `script`; `executable: false` leaves it without the x bit.
    private func makeApp(script: String, executable: Bool = true) throws -> URL {
        let app = root.appendingPathComponent("T.app")
        let dir = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("nxnative")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: exe.path)
        return app
    }

    func testLaunchPassesEnvironment() async throws {
        let out = root.appendingPathComponent("env.txt")
        let app = try makeApp(script: "#!/bin/sh\necho \"$DM_STREAM $DM_LAUNCHER\" > '\(out.path)'\nexit 3\n")
        let launcher = AppLauncher(apps: { _ in app })
        let game = try await launcher.launch(titleID: "0000000000000001", socketPath: "/tmp/x.sock")
        let code = await game.waitForExit()
        XCTAssertEqual(code, 3)
        let text = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, "/tmp/x.sock 0")
    }

    /// A game's own variables arrive; the Host's two (the tap socket, the launcher window off) are never replaced by them.
    func testLaunchEnvironmentAddsButNeverReplacesTheHostsOwn() async throws {
        let out = root.appendingPathComponent("env.txt")
        let app = try makeApp(script: "#!/bin/sh\necho \"$NX_TEST_VALUE $DM_STREAM $DM_LAUNCHER\" > '\(out.path)'\n")
        let launcher = AppLauncher(apps: { _ in app })
        let game = try await launcher.launch(titleID: "0000000000000001", socketPath: "/tmp/x.sock",
                                             environment: ["NX_TEST_VALUE": "yes", "DM_STREAM": "/elsewhere", "DM_LAUNCHER": "1"])
        _ = await game.waitForExit()
        let text = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, "yes /tmp/x.sock 0")
    }

    /// A per-game choice arrives as an environment variable (never through a shell); `DM_STREAM` stays the socket whatever the
    /// environment holds.
    func testAChoiceArrivesAsAVariableAndTheTapSocketStaysTheHosts() async throws {
        let out = root.appendingPathComponent("env.txt")
        let app = try makeApp(script: "#!/bin/sh\nenv | grep -E '^(DM_RENDER_SCALE|DM_STREAM|DM_NOTE)=' | sort > '\(out.path)'\n")
        let launcher = AppLauncher(apps: { _ in app })
        let environment = HostService.launchEnvironment(file: ["DM_STREAM": "x"], choices: ["DM_RENDER_SCALE": "0.75"])
        // Even when the Host's merge is bypassed, the launcher's own variables win.
        let game = try await launcher.launch(titleID: "0000000000000001", socketPath: "/tmp/x.sock",
                                             environment: environment.merging(["DM_STREAM": "x", "DM_NOTE": "a b; touch nothing $(x)"]) { _, new in new })
        _ = await game.waitForExit()
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["DM_NOTE=a b; touch nothing $(x)", "DM_RENDER_SCALE=0.75", "DM_STREAM=/tmp/x.sock"])
    }

    func testLogDirectoryReceivesOutput() async throws {
        let app = try makeApp(script: "#!/bin/sh\necho hello-out\necho hello-err >&2\n")
        let logs = root.appendingPathComponent("logs")
        let launcher = AppLauncher(apps: { _ in app }, logDirectory: logs)
        let game = try await launcher.launch(titleID: "0000000000000002", socketPath: "/tmp/x.sock")
        _ = await game.waitForExit()
        let text = try String(contentsOf: logs.appendingPathComponent("0000000000000002.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("hello-out") && text.contains("hello-err"), text)
    }

    func testTerminate() async throws {
        let app = try makeApp(script: "#!/bin/sh\nexec sleep 60\n")
        let launcher = AppLauncher(apps: { _ in app })
        let game = try await launcher.launch(titleID: "0000000000000001", socketPath: "/tmp/x.sock")
        await game.terminate()
        let t0 = Date()
        let code = await game.waitForExit()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertEqual(code, 128 + 15)
        await game.terminate()  // safe after exit, and twice
    }

    /// The launcher and its child both ignore TERM: the kill step reaches the child too.
    func testTerminateKillsChildren() async throws {
        let pidFile = root.appendingPathComponent("child.pid")
        let script = root.appendingPathComponent("launcher.sh")
        try "#!/bin/sh\ntrap '' TERM\nsleep 60 &\necho $! > '\(pidFile.path)'\nwait\nwait\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let game = RunningProcess(process, killGrace: 0.3)
        try game.start()
        var childPid: pid_t = 0
        for _ in 0..<200 where childPid == 0 {
            childPid = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            if childPid == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertGreaterThan(childPid, 0, "child never started")
        await game.terminate()
        let code = await game.waitForExit()
        XCTAssertEqual(code, 128 + 9)
        var gone = false
        for _ in 0..<200 where !gone {
            gone = kill(childPid, 0) != 0 && errno == ESRCH
            if !gone { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        if !gone { kill(childPid, SIGKILL) }
        XCTAssertTrue(gone, "child \(childPid) survived the kill")
    }

    /// A game that ignores SIGTERM: `terminate()` returns only once it is dead (SIGTERM, the grace, SIGKILL), so a Host that
    /// exits right after `stop()` leaves nothing running -> .claude/host.md § game-launch
    func testTerminateReturnsOnlyAfterAGameThatIgnoresTermIsDead() async throws {
        let pidFile = root.appendingPathComponent("game.pid")
        let script = root.appendingPathComponent("stubborn.sh")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nwhile :; do sleep 1; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let game = RunningProcess(process, killGrace: 0.3)
        try game.start()
        var pid: pid_t = 0
        for _ in 0..<300 where pid == 0 {
            pid = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            if pid == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertGreaterThan(pid, 0, "the game never started")
        await game.terminate()
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        XCTAssertFalse(alive, "terminate() returned while the game was still running")
        await game.terminate()  // safe after exit
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()  // guards n
        private var n = 0
        func raise() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    /// A game that survives the SIGKILL (the kill is replaced by a no-op: no real process can do this): `terminate()` gives up
    /// after the cap, once, and says so.
    func testTerminateGivesUpWhenTheGameSurvivesTheKill() async throws {
        let pidFile = root.appendingPathComponent("game.pid")
        let script = root.appendingPathComponent("stubborn.sh")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nwhile :; do sleep 1; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let stuck = Flag()
        let game = RunningProcess(process, killGrace: 0.2, exitCap: 0.4, sendKill: { _ in }, onStuck: { stuck.raise() })
        try game.start()
        var pid: pid_t = 0
        for _ in 0..<300 where pid == 0 {
            pid = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            if pid == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertGreaterThan(pid, 0)
        let t0 = Date()
        await game.terminate()
        let took = Date().timeIntervalSince(t0)
        RunningProcess.killTree(pid)  // the test's own cleanup
        XCTAssertGreaterThanOrEqual(took, 0.5, "returned before the kill and the cap")
        XCTAssertLessThan(took, 3, "terminate() waited for ever")
        XCTAssertEqual(stuck.count, 1)
        _ = await game.waitForExit()
    }

    /// A game that dies at the kill does not call `onStuck`.
    func testTerminateDoesNotReportAGameThatDied() async throws {
        let app = try makeApp(script: "#!/bin/sh\nexec sleep 60\n")
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/nxnative")
        let stuck = Flag()
        let game = RunningProcess(process, killGrace: 0.2, onStuck: { stuck.raise() })
        try game.start()
        await game.terminate()
        XCTAssertEqual(stuck.count, 0)
    }

    func testTheStuckLineNamesTheGameAndNoPath() {
        XCTAssertEqual(AppLauncher.stuckLine(titleID: "0400486024DEC000"), "0400486024DEC000: did not exit after SIGKILL")
    }

    func testNotFound() async throws {
        let launcher = AppLauncher(apps: { _ in nil })
        do {
            _ = try await launcher.launch(titleID: "0000000000000009", socketPath: "/tmp/x.sock")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? LaunchError, .notFound("0000000000000009"))
        }
    }

    func testNotRunnable() async throws {
        let app = try makeApp(script: "#!/bin/sh\n", executable: false)
        let launcher = AppLauncher(apps: { _ in app })
        do {
            _ = try await launcher.launch(titleID: "0000000000000001", socketPath: "/tmp/x.sock")
            XCTFail("expected notRunnable")
        } catch {
            guard case .notRunnable? = error as? LaunchError else { return XCTFail("\(error)") }
        }
    }
}
#endif
