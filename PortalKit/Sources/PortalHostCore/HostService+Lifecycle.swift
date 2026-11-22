#if os(macOS)
import Foundation
import Network
import os

/// What the service keeps for its own life: a failure to report -> .claude/host.md § service
struct LifecycleState {
    /// Set once the service cannot serve (a start that threw, a listener that failed); `status` is then `.failed`.
    var failure: String?
    /// The newest library scan and when it finished (uptime ns); nil = none, or the roots changed.
    var scanned: [GameApp] = []
    var scannedAt: UInt64?
    /// Counts library changes (`setLibraryRoots`): a scan that began before one is not kept.
    var libraryEpoch = 0
    /// Test hooks: awaited inside `start()` after the tap opened, and inside a library scan after it read the disk.
    var startHold: (@Sendable () async -> Void)?
    var scanHold: (@Sendable () async -> Void)?
    /// The teardown, once begun: a second `stop()` waits for it.
    var teardown: Task<Void, Never>?
}

/// Start, teardown and failure reporting -> .claude/host.md § service
extension HostService {
    private static let instances = OSAllocatedUnfairLock(initialState: 0)

    /// The next instance number of this process: two services in it never share a tap socket path.
    static func nextInstance() -> Int { instances.withLock { n in defer { n += 1 }; return n } }

    /// Test hooks (see `LifecycleState`): hold a `start()` or a scan at its await so a test can `stop()` there.
    func holdStart(_ hold: (@Sendable () async -> Void)?) { lifecycle.startHold = hold }
    func holdScan(_ hold: (@Sendable () async -> Void)?) { lifecycle.scanHold = hold }

    /// The time every session timer reads: `config.clock` (uptime unless a test drives it) -> .claude/host.md § service
    func now() -> Date { config.clock() }

    /// Everything `stop()` does, and what a `start()` that threw runs: the one teardown. Idempotent; every caller returns
    /// only when it has finished.
    func shutdown() async {
        if let running = lifecycle.teardown { return await running.value }
        stopped = true  // before any suspension: nothing opens or launches after this
        let running = Task { await self.tearDown() }
        lifecycle.teardown = running
        await running.value
    }

    private func tearDown() async {
        if let id = liveLink { reportEnd(id, by: .hostStop) }
        for t in tasks { t.cancel() }
        tasks = []
        await control.stopAndWait()  // the pinned port is free again when this returns
        for link in links.values { link.connection.cancel() }
        links = [:]
        liveLink = nil
        sender.stop()
        media.stop()
        await tap.stop()  // a connected game quits
        let handle = game?.handle
        game = nil
        await handle?.terminate()
        if awake { awake = false; config.power.set(false) }
        statusOut.finish()
        sessionEndsOut.finish()
        notesOut.finish()
    }

    /// A `start()` that threw: `.failed` with the reason, then the teardown (the object is used up).
    func startFailed(_ error: any Error) async {
        reportFailure(Self.describe(error))
        await shutdown()
    }

    /// The service is not serving: `status` says so, once; nothing after it replaces it.
    func reportFailure(_ text: String) {
        guard lifecycle.failure == nil else { return }
        lifecycle.failure = text
        lastStatus = .failed(text)
        statusOut.yield(.failed(text))
    }

    /// The control listener failed after it was ready: its connections stay, nothing new arrives.
    func listenerFailed(_ error: any Error) {
        reportFailure("The Host stopped listening for devices (\(Self.describe(error)))")
    }

    /// Text for people: no address, no path.
    static func describe(_ error: any Error) -> String {
        func posix(_ code: Int32) -> String { String(cString: strerror(code)) }
        switch error {
        case let HostServiceError.system(what, code): return "\(what): \(posix(code))"
        case let TapServerError.system(what, code): return "\(what): \(posix(code))"
        case TapServerError.pathTooLong: return "the game socket path is too long"
        case TapServerError.unsafeFolder: return "the game socket folder is not private to this user"
        case let NWError.posix(code): return posix(code.rawValue)
        default: return error.localizedDescription
        }
    }
}
#endif
