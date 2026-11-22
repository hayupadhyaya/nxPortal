#if os(macOS)
import Foundation
import Observation
import PortalKit
import PortalHostCore
import os

/// The Host menu's model: one service at a time, kept running until `stop()` -> .claude/host.md § model
/// Every sentence it shows comes from `HostMessages`. Log lines carry no device name, address or key.
@MainActor @Observable
public final class HostModel {
    public enum Phase: Equatable, Sendable {
        case stopped, starting
        case running(port: UInt16)
        /// Text for people; the model tries again unless it says the Host cannot start at all.
        case failed(String)
    }

    public private(set) var phase: Phase = .stopped
    /// The service's own status; `until` of `.pairing` is shown as it is, the model never decides expiry.
    public private(set) var status: HostStatus = .idle
    public private(set) var devices: [PairedDevice] = []
    public private(set) var games: [GameEntry] = []
    public private(set) var message: String?
    /// What the live session and the preparing game add to `status`; read from the service with the lists, never polled.
    private var detail = HostService.SessionDetail()
    /// The service's own copy of each game's icon, as the one accessor gave it (shared storage, not a second decode).
    private var icons: [String: Data] = [:]
    @ObservationIgnored private var iconHashes: [String: String] = [:]
    /// Changed through `addFolder`, `removeFolder` and `rename`.
    public private(set) var settings: HostSettings

    /// Services made and not yet stopped: the rule is at most one (two pairing stores on one secret store can lose a pairing).
    @ObservationIgnored internal private(set) var liveServices = 0
    /// The name the current (or last) service was configured with.
    @ObservationIgnored internal private(set) var activeName: String?
    /// Service failures put on show (`phase = .failed`): a stop that overtakes a failure shows none.
    @ObservationIgnored internal private(set) var failuresShown = 0
    /// Where the app's log and automated runs get their lines: listening, every status, every session end, each failure.
    /// Runs on the main actor, in the order the events happen; it must return promptly.
    @ObservationIgnored public var onEvent: (@MainActor (HostEvent) -> Void)?
    /// The second status line while a session is live (device, frame rate, rate); nil otherwise.
    public var statusDetail: String? {
        guard case let .live(device, _, _) = status, let bps = detail.bps else { return nil }
        return HostMessages.statusDetail(device: device, fps: detail.fps, bps: bps)
    }
    /// How far the game with `titleID` has got in preparing its graphics; nil when it is not preparing.
    public func preparing(titleID: String) -> Preparing? { detail.preparingTitleID == titleID ? detail.preparing : nil }
    /// The row tag of a preparing game: "preparing 36 %", or "preparing" while no progress is known; nil when it is not preparing.
    public func preparingTag(titleID: String) -> String? { preparing(titleID: titleID).map(HostMessages.preparingTag(of:)) }
    /// The game's icon (the PNG the service keeps), nil without one.
    public func gameIcon(titleID: String) -> Data? { icons[titleID] }
    /// While the menu is open: the model reads the service again every 2 s. `menuOpened()` / `menuClosed()` are the only
    /// start and stop; with the menu closed nothing runs.
    /// Second line of defence: the view says "still open" (`menuStillOpen()`) on every refresh it draws; a loop not
    /// re-affirmed for `menuLapse` (10 s, on `menuNow`) ends by itself, so a missed `menuClosed()` costs one lapse, not for ever.
    public func menuOpened() {
        guard menuLoop == nil else { return }
        onMenuEvent?("menu opened")
        menuAffirmed = menuNow()
        let tick = menuTick
        menuLoop = Task { [weak self] in
            await self?.menuRead()
            while !Task.isCancelled {
                await tick()
                if Task.isCancelled { break }
                guard let self, self.menuAffirmedRecently() else { self?.menuLapsed(); break }
                await self.menuRead()
            }
        }
    }

    /// The view drew a refresh and its menu is still open.
    public func menuStillOpen() {
        if menuLoop != nil { menuAffirmed = menuNow() }
    }

    private func menuAffirmedRecently() -> Bool { menuNow().timeIntervalSince(menuAffirmed) <= Self.menuLapse }

    private func menuLapsed() {
        menuLoop = nil
        onMenuEvent?("menu lapsed")
    }

    /// How long an open menu's loop runs without the view re-affirming it.
    static let menuLapse: TimeInterval = 10

    public func menuClosed() {
        guard let loop = menuLoop else { return }
        loop.cancel()
        menuLoop = nil
        onMenuEvent?("menu closed")
    }

    private func menuRead() async {
        await refresh()
        guard !Task.isCancelled else { return }
        menuRefreshes += 1
        onMenuEvent?("menu read \(menuRefreshes)")
    }

    /// Debug output of an automated run: "menu opened", "menu read <n>", "menu closed". Nothing in a normal run.
    @ObservationIgnored public var onMenuEvent: (@MainActor (String) -> Void)?
    @ObservationIgnored private var menuLoop: Task<Void, Never>?
    @ObservationIgnored private var menuAffirmed = Date.distantPast
    /// Reads done for an open menu (the first on opening, then one per tick); a debug counter.
    public private(set) var menuRefreshes = 0
    /// The headline while the game on the status line is still preparing; nil otherwise.
    public var preparingHeadline: String? {
        guard case let .live(device, _, game?) = status, let id = detail.preparingTitleID,
              games.first(where: { $0.titleID == id })?.name == game else { return nil }
        return HostMessages.preparingGame(game, for: device)
    }
    /// Artwork fetches from the service (the icon is fetched again only when its hash changed).
    @ObservationIgnored internal private(set) var iconFetches = 0
    /// A game is starting, running or paused: a rename ends it.
    public var gameIsActive: Bool {
        switch status {
        case .paused: return true
        case let .live(_, _, game): if game != nil { return true }
        default: break
        }
        return games.contains { $0.state != .idle }
    }

    @ObservationIgnored private let store: HostSettingsStore
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let announcer: any PairingAnnouncing
    @ObservationIgnored private let launcher: (any GameLaunching)?
    @ObservationIgnored private let extraGames: [GameApp]
    @ObservationIgnored private let port: UInt16
    @ObservationIgnored private let logDirectory: URL?
    @ObservationIgnored private let retryInterval: TimeInterval
    @ObservationIgnored private let gameEnvironment: @Sendable (String) -> [String: String]
    /// Where per-game choices are kept (the app's own folder); nil keeps them in memory only.
    @ObservationIgnored private let optionsFile: URL?
    /// Reads an app's own saved choice (`launcher.<variable>` in its bundle ID's domain); nil = the real preferences. An automated
    /// run gives one that returns nothing, so it never reads a person's.
    @ObservationIgnored private let savedChoice: (@Sendable (String, String) -> String?)?
    @ObservationIgnored private let systemRoots: [URL]
    @ObservationIgnored private let power: any PowerHolding
    @ObservationIgnored private let advertise: Bool
    /// Waits between an open menu's reads (2 s; a test's own clock).
    @ObservationIgnored private let menuTick: @Sendable () async -> Void
    /// The clock the lapse is measured on (a test's own).
    @ObservationIgnored private let menuNow: @Sendable () -> Date
    @ObservationIgnored private let makeService: @MainActor (HostConfig) async throws -> HostService
    /// The roots the default launcher looks games up in; kept current by `applyRoots()`.
    @ObservationIgnored private let lookupRoots = RootsBox()
    /// The computer's name, read once (the default name of the Host).
    @ObservationIgnored private let computerName = HostModel.readComputerName()
    /// Follows the live service's `sessionEnds` into `onEvent`; `retire` waits for it, so the last line (`host-stop`) is not lost.
    @ObservationIgnored private var endsTask: Task<Void, Never>?
    /// The failure last reported through `onEvent`; cleared when the service runs.
    @ObservationIgnored private var failureReported: String?

    /// What the person last asked for: set by `start()` (true) and `stop()` (false) only. `rename` and the retry loop read it.
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var service: HostService?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var firstAttempt: FirstAttempt?
    /// The code the announcer was last given and not yet told to withdraw.
    @ObservationIgnored private var announced: String?

    private static let log = Logger(subsystem: "nxportal", category: "model")

    public convenience init(store: HostSettingsStore, secrets: any SecretStoring, announcer: any PairingAnnouncing,
                            launcher: (any GameLaunching)? = nil, extraGames: [GameApp] = [], port: UInt16 = 0, logDirectory: URL?,
                            retryInterval: TimeInterval = 2,
                            gameEnvironment: @escaping @Sendable (String) -> [String: String] = { _ in [:] },
                            optionsFile: URL? = nil, savedChoice: (@Sendable (String, String) -> String?)? = nil) {
        self.init(store: store, secrets: secrets, announcer: announcer, launcher: launcher, extraGames: extraGames, port: port,
                  logDirectory: logDirectory, retryInterval: retryInterval, gameEnvironment: gameEnvironment, optionsFile: optionsFile,
                  savedChoice: savedChoice, systemRoots: Self.standardRoots, power: SystemPowerHold(), advertise: true,
                  makeService: { try HostService(config: $0) })
    }

    /// The injection points: the application folders, power, Bonjour and how a service is made (tests count services there).
    init(store: HostSettingsStore, secrets: any SecretStoring, announcer: any PairingAnnouncing,
         launcher: (any GameLaunching)?, extraGames: [GameApp], port: UInt16, logDirectory: URL?,
         retryInterval: TimeInterval, gameEnvironment: @escaping @Sendable (String) -> [String: String], optionsFile: URL?,
         savedChoice: (@Sendable (String, String) -> String?)?, systemRoots: [URL], power: any PowerHolding, advertise: Bool,
         menuTick: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 2_000_000_000) },
         menuNow: @escaping @Sendable () -> Date = HostConfig.monotonicNow,
         makeService: @escaping @MainActor (HostConfig) async throws -> HostService) {
        self.store = store; self.secrets = secrets; self.announcer = announcer; self.launcher = launcher
        self.extraGames = extraGames; self.port = port; self.logDirectory = logDirectory; self.retryInterval = retryInterval
        self.gameEnvironment = gameEnvironment; self.optionsFile = optionsFile; self.savedChoice = savedChoice; self.systemRoots = systemRoots; self.power = power; self.advertise = advertise
        self.makeService = makeService; self.menuTick = menuTick; self.menuNow = menuNow
        settings = store.load()
        lookupRoots.set(Self.libraryRoots(system: systemRoots, folders: settings.folders))
    }

    // MARK: library roots

    /// `/Applications` and `~/Applications`.
    public static var standardRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// The system folders, then the person's own; the same folder twice counts once, however it is spelled (a link to a
    /// folder, `/Applications` added by hand: compared by resolved path).
    static func libraryRoots(system: [URL], folders: [URL]) -> [URL] {
        var seen: Set<String> = []
        return (system + folders).map(\.standardizedFileURL).filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    var libraryRoots: [URL] { Self.libraryRoots(system: systemRoots, folders: settings.folders) }

    // MARK: lifecycle

    /// Starts the service and keeps it running: a failure is shown and tried again every `retryInterval` until it runs or
    /// `stop()`. Returns once the first attempt has run or failed. When already started (running, or waiting to retry) it
    /// returns at once: no second service, and the retry is not hastened. The last of `start()` / `stop()` wins, however the
    /// calls overlap.
    public func start() async {
        wantsRunning = true
        await begin()
    }

    /// Stops the service (a game ends with it) and the retries. Returns once nothing is running. Safe twice.
    public func stop() async {
        wantsRunning = false
        await halt()
    }

    private func begin() async {
        while let running = loop {
            if !running.isCancelled {
                if let attempt = firstAttempt { await attempt.wait() }
                return
            }
            await running.value  // a `stop()` is finishing
            guard wantsRunning else { return }  // and the person's last word was stop
        }
        guard wantsRunning else { return }
        message = nil
        failureReported = nil
        let attempt = FirstAttempt()
        firstAttempt = attempt
        loop = Task { await self.run(attempt) }
        await attempt.wait()
    }

    private func halt() async {
        guard let running = loop else {
            if case .failed = phase { phase = .stopped; status = .idle; message = nil }  // a failure that was not tried again
            return
        }
        running.cancel()
        await service?.stop()  // a start in progress throws `CancellationError`
        await running.value
    }

    /// One pass per service: make, start, follow its status; on failure stop it completely, wait, make the next.
    private func run(_ attempt: FirstAttempt) async {
        var cannotStart = false
        while !Task.isCancelled && wantsRunning {
            if case .failed = phase {} else { phase = .starting }
            let svc: HostService
            do { svc = try await makeService(makeConfig()) } catch {
                if !Task.isCancelled { cannotStart = true; setupFailed(error) }
                break
            }
            liveServices += 1
            service = svc
            if Task.isCancelled { await retire(svc); break }
            await svc.setLibraryRoots(libraryRoots)  // a folder added while the service was being made
            var reason: String
            do {
                let bound = try await svc.start()
                endsTask = Task { for await r in svc.sessionEnds { self.onEvent?(.sessionEnd(r.line)) } }
                if Task.isCancelled { await retire(svc); break }
                phase = .running(port: bound)
                message = nil
                failureReported = nil
                onEvent?(.listening(port: bound))
                await reload(from: svc)
                attempt.release()
                let ended = await follow(svc)
                if ended == nil || Task.isCancelled { await retire(svc); break }  // stopped: a failure that overtook the stop is not shown
                reason = ended ?? HostMessages.unknownReason
            } catch {
                if error is CancellationError || Task.isCancelled { await retire(svc); break }  // beaten by `stop()`: not a failure
                reason = await failureText(of: svc)
            }
            Self.log.error("the Host service failed; trying again")
            failuresShown += 1
            phase = .failed(reason)
            status = .failed(reason)
            message = HostMessages.serviceFailed(reason)
            reportFailure(reason)
            devices = []; games = []; detail = HostService.SessionDetail(); icons = [:]; iconHashes = [:]
            await withdrawIfAnnounced()
            await retire(svc)  // completely stopped before the next one is made
            attempt.release()
            do { try await Task.sleep(nanoseconds: UInt64(max(retryInterval, 0) * 1_000_000_000)) } catch { break }
        }
        await withdrawIfAnnounced()
        if !cannotStart {
            phase = .stopped; status = .idle; devices = []; games = []; detail = HostService.SessionDetail(); icons = [:]; iconHashes = [:]; message = nil
        }
        loop = nil
        attempt.release()
    }

    /// The status until the service ends: nil when it ended without failing (stopped), else the failure's text.
    private func follow(_ svc: HostService) async -> String? {
        for await s in svc.status {
            if case let .failed(text) = s { return text }
            let shown = await svc.sessionDetail()
            status = s; detail = shown  // one step: the line never pairs a new status with the last session's numbers
            onEvent?(.status(s))
            if case let .pairing(code, _) = s {
                if announced != code { announced = code; await announcer.announce(code: code) }
            } else { await withdrawIfAnnounced() }
            await reload(from: svc)
        }
        return nil
    }

    /// A start that threw has published `.failed(text)` and finished its status before it rethrew.
    private func failureText(of svc: HostService) async -> String {
        for await s in svc.status { if case let .failed(text) = s { return text } }
        return HostMessages.unknownReason
    }

    /// Stops the service (waits for it) and forgets it.
    private func retire(_ svc: HostService) async {
        await svc.stop()
        await endsTask?.value  // the stream finished with the service
        endsTask = nil
        if service === svc { service = nil }
        liveServices -= 1
    }

    private func withdrawIfAnnounced() async {
        guard announced != nil else { return }
        announced = nil
        await announcer.withdraw()
    }

    /// The service could not even be made: the identity cannot be read, or the game socket cannot be placed. Retrying cannot
    /// cure either; a later `start()` by the person tries again.
    private func setupFailed(_ error: any Error) {
        let text = error is TapServerError ? HostMessages.setupFailed : HostMessages.identityUnreadable
        phase = .failed(text)
        status = .failed(text)
        message = text
        reportFailure(text)
        Self.log.error("the Host service could not be made; not tried again")
    }

    /// One `.failed` event per reason until the service runs again (the retries repeat the same one).
    private func reportFailure(_ text: String) {
        guard failureReported != text else { return }
        failureReported = text
        onEvent?(.failed(text))
    }

    private static func readComputerName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private func makeConfig() -> HostConfig {
        let name = settings.name ?? computerName
        activeName = name
        let roots = libraryRoots
        let lookup = lookupRoots
        let launching: any GameLaunching = launcher ?? AppLauncher(
            apps: { titleID in GameLibrary(roots: lookup.get()).scan().first { $0.titleID == titleID }?.url },
            logDirectory: logDirectory,
            report: { [weak self] line in Task { @MainActor in self?.onEvent?(.note(line)) } })
        // `storeURL` is never read or written: the pairing store is in `secrets`.
        var config = HostConfig(name: name, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("nxportal-unused"),
                                libraryRoots: roots, launcher: launching, power: power, advertise: advertise, port: port,
                                extraGames: extraGames, maxBitrate: settings.maxBitrate)
        config.secrets = secrets
        config.gameEnvironment = gameEnvironment
        config.optionsURL = optionsFile
        if let savedChoice { config.savedChoice = savedChoice }
        return config
    }

    // MARK: reading the service

    /// Devices and games, as the service has them now.
    public func refresh() async {
        guard let svc = service, case .running = phase else { return }
        await reload(from: svc)
    }

    private func reload(from svc: HostService) async {
        let devices = await svc.devices()
        let games = await svc.games()
        let detail = await svc.sessionDetail()
        // an icon is fetched only when its hash is not the one kept
        var icons: [String: Data] = [:], hashes: [String: String] = [:]
        for g in games {
            guard let art = g.art else { continue }
            if iconHashes[g.titleID] == art.hash, let kept = self.icons[g.titleID] { icons[g.titleID] = kept; hashes[g.titleID] = art.hash; continue }
            iconFetches += 1
            if let png = await svc.artwork(titleID: g.titleID) { icons[g.titleID] = png; hashes[g.titleID] = art.hash }
        }
        guard service === svc, case .running = phase else { return }  // not after the service failed
        self.devices = devices
        self.games = games
        if self.detail != detail { self.detail = detail }
        if iconHashes != hashes { self.icons = icons; iconHashes = hashes }
    }

    // MARK: calls

    public func beginPairing() async {
        message = nil
        guard let svc = service, case .running = phase else { message = HostMessages.notRunning; return }
        do { _ = try await svc.beginPairing() } catch { message = HostMessages.problem(error) }
    }

    public func cancelPairing() async {
        await service?.cancelPairing()
    }

    /// Unpairs the device and ends its session. When the change cannot be saved the session has ended anyway and the device
    /// stays listed (it is still paired): `message` says so.
    public func remove(_ device: PairedDevice) async {
        message = nil
        guard let svc = service, case .running = phase else { message = HostMessages.notRunning; return }
        do { try await svc.removeDevice(device.id) } catch {
            if let known = error as? HostServiceError, known == .stopped { message = HostMessages.notRunning } else {
                message = HostMessages.couldNotRemove(device.shownName)
            }
        }
        await reload(from: svc)
    }

    /// What the rename field starts with: the Host's own name if there is one, else the device's own name; never the computed
    /// numbered name (saving that unchanged would pin the number).
    public func renameDraft(for device: PairedDevice) -> String { device.alias ?? device.name }

    /// The Host's own name for a paired device; nil, or a name that cleans to nothing, removes it. Allowed while the device is
    /// connected; nothing is sent to it. `message` says so when the change could not be saved.
    public func rename(_ device: PairedDevice, to name: String?) async {
        message = nil
        guard let svc = service, case .running = phase else { message = HostMessages.notRunning; return }
        // A draft that is what the field started with changes nothing (no alias is made of the device's own name).
        if let name, DeviceName.clean(name) == DeviceName.clean(renameDraft(for: device)), DeviceName.clean(name) != nil { return }
        do { try await svc.renameDevice(device.id, to: name) } catch {
            if let known = error as? HostServiceError, known == .stopped { message = HostMessages.notRunning } else {
                message = HostMessages.couldNotRename(device.shownName)
            }
        }
        await reload(from: svc)
    }

    public func addFolder(_ url: URL) async {
        message = nil
        let folder = url.standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            message = HostMessages.folderMissing
            return
        }
        let resolved = folder.resolvingSymlinksInPath().path
        let known = systemRoots + settings.folders
        guard !known.contains(where: { $0.resolvingSymlinksInPath().path == resolved }) else { return }
        settings.folders.append(folder)
        store.save(settings)
        await applyRoots()
    }

    public func removeFolder(_ url: URL) async {
        message = nil
        let path = url.standardizedFileURL.path
        settings.folders.removeAll { $0.standardizedFileURL.path == path }
        store.save(settings)
        await applyRoots()
    }

    /// nil (or only blanks) = the computer's name. The name is saved, and a running Host restarts: the network name changes.
    /// The restart ends a running or paused game and every session; `rename` does not refuse, so the app asks first
    /// (`gameIsActive`). A `stop()` that lands meanwhile wins: the name is saved and the Host stays stopped.
    public func rename(_ name: String?) async {
        message = nil
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        settings.name = trimmed.isEmpty ? nil : trimmed
        store.save(settings)
        guard wantsRunning, let running = loop, !running.isCancelled else { return }
        await halt()
        guard wantsRunning else { return }
        await begin()
    }

    /// A line for the person from outside the model (the app: a file it could not use).
    public func show(message text: String) { message = text }

    public func quitGame() async {
        await service?.quitGame()
    }

    private func applyRoots() async {
        lookupRoots.set(libraryRoots)
        await service?.setLibraryRoots(libraryRoots)
        await refresh()
    }
}

/// The folders the default launcher searches, readable from its own thread.
private final class RootsBox: @unchecked Sendable {  // lock-guarded
    private let lock = NSLock()  // guards roots
    private var roots: [URL] = []
    func get() -> [URL] { lock.withLock { roots } }
    func set(_ new: [URL]) { lock.withLock { roots = new } }
}

/// Lets `start()` return once the first attempt has run or failed.
@MainActor
private final class FirstAttempt {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let all = waiters
        waiters = []
        for w in all { w.resume() }
    }
}
#endif
