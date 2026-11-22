#if os(macOS)
import Foundation

public enum LaunchError: Error, Equatable {
    case notFound(String)
    case notRunnable(String)
}

public protocol GameLaunching: Sendable {
    func launch(titleID: String, socketPath: String) async throws -> any RunningGame
    /// `environment` is added to the game's; the launcher's own variables (the tap socket, the launcher window off) win.
    func launch(titleID: String, socketPath: String, environment: [String: String]) async throws -> any RunningGame
}

extension GameLaunching {
    /// A launcher that does not take an environment ignores it.
    public func launch(titleID: String, socketPath: String, environment: [String: String]) async throws -> any RunningGame {
        try await launch(titleID: titleID, socketPath: socketPath)
    }
}

public protocol RunningGame: Sendable {
    /// SIGTERM, then SIGKILL (children first) after 5 s; returns once the game has exited. Safe twice and after exit.
    func terminate() async
    /// Exit status; 128 + signal after a signal death.
    func waitForExit() async -> Int32
    /// The game's process id for the load sampler (a number only); nil when there is none to read.
    var pid: Int32? { get }
}

extension RunningGame {
    public var pid: Int32? { nil }
}

/// Runs `<app>/Contents/MacOS/nxnative` -> .claude/host.md § game-launch
public struct AppLauncher: GameLaunching {
    private let apps: @Sendable (String) -> URL?
    private let logDirectory: URL?
    private let report: @Sendable (String) -> Void

    /// `report` gets one line when a game does not exit after SIGKILL (its title ID, no path).
    public init(apps: @escaping @Sendable (String) -> URL?, logDirectory: URL? = nil, report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.apps = apps
        self.logDirectory = logDirectory
        self.report = report
    }

    static func stuckLine(titleID: String) -> String { "\(titleID): did not exit after SIGKILL" }

    public func launch(titleID: String, socketPath: String) async throws -> any RunningGame {
        try await launch(titleID: titleID, socketPath: socketPath, environment: [:])
    }

    public func launch(titleID: String, socketPath: String, environment: [String: String]) async throws -> any RunningGame {
        guard let app = apps(titleID) else { throw LaunchError.notFound(titleID) }
        let exe = app.appendingPathComponent("Contents/MacOS/nxnative")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw LaunchError.notRunnable(exe.path) }
        let process = Process()
        process.executableURL = exe
        var env = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
        env["DM_STREAM"] = socketPath
        env["DM_LAUNCHER"] = "0"
        process.environment = env
        var log: FileHandle?
        if let dir = logDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(titleID).log")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            log = handle
        }
        defer { try? log?.close() }
        let line = Self.stuckLine(titleID: titleID), report = report
        let running = RunningProcess(process, onStuck: { report(line) })
        try running.start()
        return running
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()  // guards done
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

final class RunningProcess: RunningGame, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()  // guards status, waiters
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private let killGrace: TimeInterval
    private let exitCap: TimeInterval
    private let sendKill: @Sendable (pid_t) -> Void
    private let onStuck: @Sendable () -> Void

    var pid: Int32? { process.processIdentifier > 0 ? process.processIdentifier : nil }

    /// `killGrace`: seconds between SIGTERM and SIGKILL. `exitCap`: how long `terminate()` waits for the exit after the SIGKILL
    /// before it gives up and calls `onStuck`. `sendKill` is the SIGKILL itself (a test replaces it).
    init(_ process: Process, killGrace: TimeInterval = 5, exitCap: TimeInterval = 3,
         sendKill: @escaping @Sendable (pid_t) -> Void = RunningProcess.killTree, onStuck: @escaping @Sendable () -> Void = {}) {
        self.process = process; self.killGrace = killGrace; self.exitCap = exitCap; self.sendKill = sendKill; self.onStuck = onStuck
    }

    /// SIGKILL to the launcher's children first, then the launcher: SIGKILL is not forwarded -> .claude/host.md § game-launch
    @Sendable static func killTree(_ pid: pid_t) {
        for child in children(of: pid) { kill(child, SIGKILL) }
        kill(pid, SIGKILL)
    }

    private var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return status != nil }

    func start() throws {
        process.terminationHandler = { [self] p in
            let code = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
            lock.lock()
            status = code
            let w = waiters
            waiters = []
            lock.unlock()
            for c in w { c.resume(returning: code) }
        }
        try process.run()
    }

    func terminate() async {
        guard !hasExited else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [self] in
            guard !hasExited else { return }
            sendKill(pid)
        }
        // Capped: a game in uninterruptible I/O can outlive its SIGKILL, and nothing may wait for it for ever.
        if await !exited(within: killGrace + exitCap) { onStuck() }
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let n = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(pids.prefix(Int(n)).filter { $0 > 0 }) : []
    }

    /// Whether the game has exited within `seconds` (false: it has not).
    func exited(within seconds: TimeInterval) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            Task { _ = await waitForExit(); if once.first() { c.resume(returning: true) } }
            Task { try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000)); if once.first() { c.resume(returning: false) } }
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { c in
            lock.lock()
            if let s = status { lock.unlock(); c.resume(returning: s); return }
            waiters.append(c)
            lock.unlock()
        }
    }
}
#endif
