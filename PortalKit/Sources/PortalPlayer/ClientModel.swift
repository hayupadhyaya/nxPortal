import Foundation
import Network
import Observation
import PortalKit
import PortalClientCore

/// The one object the views observe: discovery, pairing, the session and its screen -> .claude/client.md § model
@MainActor @Observable public final class ClientModel {
    /// One snapshot of the numbers behind the stats panel -> .claude/client.md § app
    public struct PlayStats: Equatable, Sendable {
        /// Frames a second the Mac delivered (the session's last 2 s).
        public var macFps = 0.0
        /// Pictures a second that got a display refresh of their own, and pictures a second that never did
        /// (from `displayCounts`; 0 until the view reports).
        public var shownFps = 0.0, late = 0.0
        public var width = 0, height = 0
        public var bitrateMbps = 0.0
        /// Capture to display: median and 95th percentile.
        public var delayMs = 0.0, delayP95Ms = 0.0
        public var rttMs = 0.0
        public var gapP95Ms = 0.0, gapMaxMs = 0.0
        public var skipped = 0, keyRequests = 0
        /// Frames the Mac never sent, total (`SessionStats.sourceGaps`).
        public var sourceGaps = 0
        /// Median decode time of the last 120 pictures.
        public var decodeMs = 0.0
        /// The sound buffer's target now; `soundAuto`: it follows the link.
        public var soundBufferMs = 0
        public var soundAuto = false
        public var soundUnderruns = 0, soundLost = 0
        /// The Host's own counts, newest `hostStats` (nil before the first).
        public var host: HostStats?
        /// The Mac's load, newest `load` while it is fresh (nil: none sent, or none for 3 s).
        public var load: HostLoad?
        /// The video rate now (what the Host applied, from `hostStats`; the session's own wish before the first), its
        /// ceiling (the bitrate setting) in Mbit/s, and the session's cuts -> .claude/client.md § rate
        public var rateMbps = 0.0, ceilingMbps = 0.0, rateCuts = 0
        /// Loss repair (`SessionStats`, totals of the video stream): fragments asked for and recovered, frames put out
        /// after a `nack`, frames given up; `repair` requests, escalations to a key request, key frames decoded after the first.
        public var fragmentsAsked = 0, fragmentsRecovered = 0, framesRepaired = 0, framesGivenUp = 0
        public var repairRequests = 0, escalations = 0, keys = 0
        /// Why the rate last changed (`RateReason.rawValue`); empty before the first change.
        public var rateWhy = ""
        /// Pictures the pacer keeps waiting after a refresh (0 in `immediate`).
        public var queueTarget = 0

        /// The numbers that are the session's own counters.
        mutating func fill(from s: SessionStats, queueTarget: Int) {
            fragmentsAsked = s.fragmentsAsked; fragmentsRecovered = s.fragmentsRecovered
            framesRepaired = s.framesRepaired; framesGivenUp = s.framesGivenUp
            repairRequests = s.repairRequests; escalations = s.escalations; keys = s.keys
            rateWhy = s.rateChanges.last?.why.rawValue ?? ""
            self.queueTarget = queueTarget
        }
    }

    public enum Screen: Equatable { case hosts, pairing(FoundHost), library, playing }

    // Set here and in ClientModel+Play.swift: read-only outside the module.
    public internal(set) var screen: Screen = .hosts
    public internal(set) var found: [FoundHost] = []
    public internal(set) var games: [GameEntry] = []
    /// The library is connected and no list has come yet (and none is cached): "loading", not "no games".
    public var libraryLoading: Bool {
        LibraryText.showsLoading(connected: macState == .connected, listed: gamesListed, games: games.count, failed: listFailed)
    }
    /// A games list has come from the Mac in this library (an empty one is then really "no games").
    public internal(set) var gamesListed = false
    /// Why the game sends no frames now (the panel's Game line says "paused" or "starting" instead of "no frames").
    public var panelNote: PanelText.GameNote? { PanelText.note(preparing: preparing != nil, run: gameState?.run) }
    /// The list request failed or timed out (the session's reply timeout) and no list has come since.
    public internal(set) var listFailed = false
    public var libraryCouldNotLoad: Bool {
        LibraryText.showsCouldNotLoad(connected: macState == .connected, listed: gamesListed, games: games.count, failed: listFailed)
    }
    public internal(set) var gameState: GameState?
    public internal(set) var message: String?
    /// The pairing sheet's last refusal of the code (nil: none); only a wrong code asks to type it again.
    public internal(set) var pairingResult: PairResult?
    /// The sheet's boxes are red: the last refusal was a wrong code.
    public var pairingRejected: Bool { if case .wrongCode? = pairingResult { true } else { false } }
    /// The game a controller's Y opens: the focused tile's, listed on the current Mac.
    public func optionsTarget(focused: String?) -> String? {
        guard let focused, games.contains(where: { $0.titleID == focused }) else { return nil }
        return focused
    }
    /// Why the current Mac's library is unusable (nil: nothing); `Messages.banner` words it for the library.
    public internal(set) var problem: Messages.Problem?
    public internal(set) var reconnecting = false
    /// The current Mac's name: the library's title (set while a session is open, being regained or lost); nil with no paired Mac.
    public internal(set) var hostName: String?
    /// How it goes with the current Mac -> .claude/client.md § model
    public internal(set) var macState: MacState = .looking
    /// First run: since when the app has looked for a Mac ("Still looking" after 30 s); nil once a paired Mac exists.
    public internal(set) var lookingSince: Date?
    /// The title of the tile that last opened play (focus goes back to it); kept by `leave()`, replaced by the next launch.
    public internal(set) var lastPlayedTile: String?
    /// The title last played on the current Mac from this device (`LibraryCache.lastPlayed`).
    public internal(set) var lastPlayedTitle: String?
    /// Icons that arrived or were read from `artCache`, and their palettes, by `artKey` -> `ClientModel+Art.swift`.
    var artData: [String: Data] = [:]
    var artPalettes: [String: ArtPalette] = [:]
    /// The games' own options as the open session's Mac listed them (cleaned), by title; dropped with the session or on a
    /// switch of Mac. What the person changed and the Host has not yet answered sits over them (`options(for:)`)
    /// -> `ClientModel+Options.swift`.
    var optionLists: [String: GameOptions] = [:]
    var optionWishes: [String: [String: OptionWish]] = [:]
    /// Titles whose options were reset and not yet answered (every row shows its default meanwhile).
    var optionResets: Set<String> = []
    /// The paired Macs and the current one (the session's, else the last used), kept in step with the store.
    public internal(set) var peers: [PairedPeer] = []
    public internal(set) var current: PairedPeer?
    /// What the Mac says about the game's graphics preparation (`GameState.preparing`); nil when it is not preparing.
    /// `.waiting` (total 0) is preparing with nothing to count.
    public internal(set) var preparing: Preparing?
    /// When this preparation was first seen (the elapsed time counts from it); nil when `preparing` is nil.
    public internal(set) var preparingSince: Date?
    /// Set by the view: the session's gate has opened (play begins, a reconnect completed); it sends `ControllerInput.sendCurrent()`.
    public var onInputWanted: (@MainActor () -> Void)?
    /// True while the Host has been silent for a second (the session's `stalls`): the view says so over the frozen picture.
    public internal(set) var stalled = false {
        didSet { if !stalled { stallStart = nil }; refreshTrouble() }
    }
    /// What the view shows over the frozen picture: `stalled`, kept until the first new picture is shown after recovery or 1 s after it.
    public internal(set) var showsReconnecting = false
    /// What the play screen says about the silence -> `TroubleStage`.
    public internal(set) var trouble: TroubleStage = .none
    /// The time source of the silence count, in seconds (the model keeps no wall clock of its own: tests drive this).
    @ObservationIgnored var clock: () -> TimeInterval
    /// When the picture stopped for the stage being shown (on `clock`); the stall signal fires after about a second of silence.
    @ObservationIgnored var stallStart: TimeInterval?
    /// The ended card's sentence while the session is gone and the play screen waits for the person (or the reconnect loop).
    @ObservationIgnored var endedReason: String?
    @ObservationIgnored var troubleTask: Task<Void, Never>?

    /// `trouble` from the silence so far: only while the stall signal is on (no datagram of any kind for about a second:
    /// 1 s + the time since on `clock`), so it clears the moment the link is back and never follows a picture that is late
    /// by design (a game starting, "Apply and reconnect"). A task re-reads it a few times a second while stalled.
    func refreshTrouble() {
        if stalled, stallStart == nil { stallStart = clock() }
        let silence = stalled ? stallStart.map { TroubleStage.pillAfter + max(0, clock() - $0) } : nil
        let next = TroubleStage.at(silence: silence, ended: endedReason)
        if next != trouble { trouble = next }
        if stalled, troubleTask == nil {
            troubleTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.refreshTrouble()
                }
            }
        } else if !stalled {
            troubleTask?.cancel()
            troubleTask = nil
        }
    }

    /// Nothing opens the in-play menu over the ended card or the "reconnecting" screen.
    public var menuAllowed: Bool { !trouble.covers }

    /// The starting / preparing card is over the picture: the game prepares, or it is starting and no picture has shown yet.
    /// The one condition the play screen draws the card by and counts as a cover (`PlayRoute.covered`).
    public var startingCard: Bool { preparing != nil || (gameState?.run == .starting && !pictureShown) }

    /// The ended card's "Reconnect": one attempt now, resuming the play; the retry loop goes on after a miss. The card stays
    /// until a session attaches, the loop gives up, or the person leaves.
    public func reconnectNow() async {
        guard endedReason != nil, link == nil, let target else { return }
        enterBusy()
        defer { leaveBusy() }
        let reason = endedReason
        let token = begin()
        endedReason = reason
        refreshTrouble()
        switch await reopen(target, token: token, resume: playChosen) {
        case .done, .stopped: break
        case .again: startRetry(target)
        }
    }

    /// Refreshed once a second while playing.
    public internal(set) var stats: SessionStats?
    /// What the play screen's stats panel shows, refreshed about twice a second while `.playing`; nil otherwise.
    public internal(set) var playStats: PlayStats?
    /// Pictures of the current play that never got a display refresh of their own (the sum of `displayCounts`).
    public internal(set) var latePictures = 0
    /// True once a picture of the current play reached the display (`picturesShown`); false when play starts or stops.
    public internal(set) var pictureShown = false
    /// Sound output counters, read with `stats` (they reset when the output stops).
    public internal(set) var soundUnderruns = 0
    public internal(set) var soundLost = 0
    /// True while the last store operation failed: the view offers `resetStore()` next to the message.
    public internal(set) var storeFailed = false
    /// Set while the browser cannot search (local network access not allowed, or an mDNS error).
    public internal(set) var discoveryMessage: String?
    /// True while `choose`, `pair`, `foreground` or `resetStore` runs: the view disables its buttons.
    public internal(set) var busy = false
    /// Saved by the view on every change. `playSound` also reaches a session that is already open (its sound gate and output).
    public var settings: ClientSettings {
        didSet { if settings.playSound != oldValue.playSound { soundSettingChanged() } }
    }
    /// What the open session was connected with: the settings that need a new connection (`pendingReconnect`).
    var connectedWith: ConnectionShape?
    /// The display's maximum refresh rate, set by the view that knows it; the recorder's header carries it.
    public var displayMaxHz: Int?

    /// Called on the decode task for every picture to show; the view enqueues it.
    public var onPicture: (@Sendable (DecodedFrame) -> Void)? {
        get { sink.handler }
        set { sink.handler = newValue }
    }

    /// The session's `end` that starts the retry loop.
    static let lostEnds: Set<SessionEnd> = [.hostClosed, .silence, .mediaPathSilent]
    /// Sessions in a row whose media never arrived before the retry loop stops with `Messages.mediaPathBlocked`.
    static let mediaPathAttempts = 3

    @ObservationIgnored let store: ClientStore
    @ObservationIgnored let renders: RenderMemory
    /// What each game was last seen to render on this device, by title (`RenderMemory`).
    public internal(set) var knownRender: [String: RenderSize] = [:]
    @ObservationIgnored let browser: any HostBrowsing
    /// Tests: the name the model uses instead of the setting's or the model's.
    @ObservationIgnored let deviceNameOverride: String?
    /// The name this device gives a Mac, at pairing and in every `hello`: the setting, cleaned, else the model's name
    /// (`DeviceModelName`) -> .claude/client.md § settings
    var deviceName: String { deviceNameOverride ?? DeviceName.clean(settings.deviceName) ?? DeviceModelName.current() }
    @ObservationIgnored let kind: DeviceKind
    @ObservationIgnored let sound: Bool
    @ObservationIgnored let retryInterval: TimeInterval
    @ObservationIgnored let silenceTimeout: TimeInterval
    /// Shortened by tests: how long the retry loop runs, how long a quit may go unanswered.
    @ObservationIgnored let retryLimit: TimeInterval
    @ObservationIgnored let quitWait: TimeInterval
    /// How long `openLastMac` waits for the browser to list the Mac before it is `.unreachable`.
    @ObservationIgnored let lookupLimit: TimeInterval
    @ObservationIgnored let cache: LibraryCache?
    @ObservationIgnored let artCache: ArtCache?
    /// Icons being read from the cache, waiting to be asked, and asked (at most `maxArtInFlight`); `artRequestsSent` counts asks.
    @ObservationIgnored var artLoading: Set<String> = []
    @ObservationIgnored var artQueue: [(titleID: String, ref: ArtRef)] = []
    @ObservationIgnored var artInFlight: [String: ArtTransfer] = [:]
    @ObservationIgnored var artRequestsSent = 0
    /// Which asked transfer of a title is current: each ask has its own give-up timer (`artGaveUp`).
    @ObservationIgnored var artGenerations: [String: Int] = [:]
    @ObservationIgnored var artGenerationCounter = 0
    /// Titles asked about in this session (a reply for any other is dropped), the options messages sent and not yet answered
    /// per title, who waits for them, and the send chain (messages go out in the order the person made them).
    @ObservationIgnored var optionAsked: Set<String> = []
    @ObservationIgnored var optionInFlight: [String: Int] = [:]
    /// The options messages sent and not yet answered, oldest first across all titles (the Host answers in the order it
    /// got them); a refused reply answers the first.
    @ObservationIgnored var optionOrder: [OptionAsk] = []
    @ObservationIgnored var optionAskCounter = 0
    @ObservationIgnored var settleTitle: String?
    /// Titles whose list the Mac's answer could not give (a refused reply): the page says so instead of "loading".
    @ObservationIgnored var optionLoadFailed: Set<String> = []
    /// How long a call waits for the Mac's answers before it gives up (the session's own reply time).
    @ObservationIgnored var optionReplyTimeout: TimeInterval = ClientSession.replyTimeout
    @ObservationIgnored var optionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored var optionSend: Task<Bool, Never>?
    @ObservationIgnored var optionWishCounter = 0
    /// Tests: runs before every options message is sent; a throw is a message that could not go.
    @ObservationIgnored var optionSendHook: (@Sendable () async throws -> Void)?
    /// The title of a launch not yet answered by a state.
    @ObservationIgnored var launchAsked: String?
    /// The open (or last) session plays: it was opened resuming, or the Host confirmed a game the person chose in it (a
    /// `starting` / `running` state of that game). A library session that has not stays on `.library` whatever the game's
    /// state; cleared at once by `leave()` and `goHome` -> .claude/client.md § model
    public internal(set) var playChosen = false
    /// The game `launch` / `resume` asked to play, until the Host's answer confirms it or refuses it (a state with a
    /// reason); "" = whichever game is running.
    @ObservationIgnored var playAsked: String?
    @ObservationIgnored let sink = PictureSink()

    /// The open session and its tasks; nil when none is open.
    @ObservationIgnored var link: Link?
    @ObservationIgnored var nextLinkID = 0
    /// The Mac of the open (or last open) session: reconnect and `foreground()` go back to it.
    @ObservationIgnored var target: (host: FoundHost, peer: PairedPeer)?
    /// Bumped by every user action; work begun under an older value is dropped when it resumes.
    @ObservationIgnored var op = 0
    @ObservationIgnored var browseTask: Task<Void, Never>?
    @ObservationIgnored var openTask: Task<Void, Never>?
    @ObservationIgnored var failuresTask: Task<Void, Never>?
    @ObservationIgnored var busyCount = 0
    /// The `op` the running `pair(code:)` belongs to; a newer action supersedes it, so its late end blocks nothing.
    @ObservationIgnored var pairingOp: Int?
    /// Bumped by every pairing sheet opened, cancelled or sent; it supersedes a `pair` without touching the open Mac's work
    /// (its reconnect loop, its quit timer): those belong to `op`.
    @ObservationIgnored var pairSeq = 0
    /// `background()` came while a pairing sheet was open: `foreground()` could not take the Mac up again under it, so closing
    /// the sheet does. Cleared by any session that attaches.
    @ObservationIgnored var resumeAfterSheet = false
    /// The Mac chosen in this run that has not connected (yet): current for this run, but only a connect sets the stored last Mac.
    @ObservationIgnored var chosenKey: Data?
    /// Players sent during the current play; each gets a neutral input when play stops.
    @ObservationIgnored var playersSent: Set<UInt8> = []
    /// The newest real input per player (the controller reports changes only); sent again on recovery from a stall.
    @ObservationIgnored var lastInputs: [UInt8: InputState] = [:]
    @ObservationIgnored var overlayTask: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    /// Sessions in a row that ended `mediaPathSilent`; any other end or a user action starts again from 0.
    @ObservationIgnored var mediaPathFailures = 0
    @ObservationIgnored var quitTask: Task<Void, Never>?
    @ObservationIgnored var statsTask: Task<Void, Never>?
    /// Where session numbers go (nil: nowhere); the session recorder's task and the view's newest report with its time.
    @ObservationIgnored let recordingsDirectory: URL?
    @ObservationIgnored var recorderTask: Task<Void, Never>?
    /// The newest `applyLive` send; the next one waits for it, so the Host sees the changes in the order they were made.
    @ObservationIgnored var liveTask: Task<Void, Never>?
    @ObservationIgnored var displayReport: (report: DisplayReport, atNs: UInt64)?
    /// The view's last report (`displayCounts`), per second.
    @ObservationIgnored var displayShownFps = 0.0
    @ObservationIgnored var displayLate = 0.0
    @ObservationIgnored var quitAsked = false
    @ObservationIgnored var listAsked = 0
    @ObservationIgnored var listShown = 0

    /// Stream size and frame rate: fixed by the `hello`, so a change needs a new connection (the bitrate ceiling does not).
    struct ConnectionShape: Equatable { var width: UInt16, height: UInt16, fps: UInt8 }

    /// Thrown when a newer action took over while this one waited.
    struct Superseded: Error {}

    /// The session this model has open (tests).
    var session: ClientSession? { link?.session }

    public init(store: ClientStore, browser: any HostBrowsing, deviceName: String? = nil, kind: DeviceKind,
                settings: ClientSettings = .init(), sound: Bool = true, retryInterval: TimeInterval = 2, silenceTimeout: TimeInterval = ClientSession.defaultSilenceTimeout,
                recordingsDirectory: URL? = nil, retryLimit: TimeInterval = 300,
                quitWait: TimeInterval = 6, lookupLimit: TimeInterval = 5, cache: LibraryCache? = nil, artCache: ArtCache? = nil, defaults: UserDefaults = .standard,
                clock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }) {
        self.clock = clock
        self.lookupLimit = lookupLimit; self.cache = cache; self.artCache = artCache
        self.renders = RenderMemory(defaults: defaults)
        self.knownRender = renders.all
        self.retryLimit = retryLimit; self.quitWait = quitWait
        self.recordingsDirectory = recordingsDirectory
        self.store = store; self.browser = browser; self.deviceNameOverride = deviceName.flatMap(DeviceName.clean); self.kind = kind
        self.settings = settings; self.sound = sound; self.retryInterval = retryInterval; self.silenceTimeout = silenceTimeout
    }

    /// No task outlives the model; the session is released with it (the Host sees the connection end).
    deinit {
        browseTask?.cancel()
        openTask?.cancel()
        failuresTask?.cancel()
        retryTask?.cancel()
        quitTask?.cancel()
        troubleTask?.cancel()
        statsTask?.cancel()
        recorderTask?.cancel()
        liveTask?.cancel()
        link?.cancel()
        browser.stop()
    }

    // MARK: calls

    /// Sets the first screen from the store (before any render), starts browsing (`found` follows the browser) and
    /// opens the last Mac in a task; no paired Mac: the first-run screen.
    public func start() {
        guard browseTask == nil else { return }
        reloadPeers()
        if let peer = pickCurrent() {
            show(peer)
            screen = .library
            macState = .looking
        } else {
            screen = .hosts
            lookingSince = Date()
            if storeFailed { message = Messages.storeFailed }
        }
        let hosts = browser.hosts
        browseTask = Task { [weak self] in
            for await list in hosts { self?.found = list }
        }
        let failures = browser.failures
        failuresTask = Task { [weak self] in
            for await failed in failures { self?.discoveryMessage = failed ? Messages.discoveryBlocked : nil }
        }
        browser.start()
        if current != nil {
            let token = begin()  // taken now: a user action before the task runs supersedes it
            openTask = Task { [weak self] in await self?.openLastMac(token: token) }
        }
    }

    /// A paired Mac becomes the current one (name, cached games, last used) before the connect, so a failure lands on its
    /// own library; the open session closes then. Not paired: `.pairing(host)` and the open session stays until a pairing succeeds.
    public func choose(_ host: FoundHost) async {
        enterBusy()
        defer { leaveBusy() }
        let peer: PairedPeer?
        do { peer = try withStore { try store.hosts() }.first { Self.same($0, host) } } catch {
            _ = begin()
            goHome(.storeFailed)
            return
        }
        guard let peer else {
            // No `begin()`: the Mac that is open keeps its reconnect loop and quit timer under the sheet.
            pairSeq += 1
            screen = .pairing(host)
            message = nil
            pairingResult = nil
            return
        }
        let token = begin()
        let closing = teardown()
        target = nil
        gameState = nil
        chosenKey = peer.key
        show(peer)
        screen = .library
        macState = .connecting
        message = nil
        problem = nil
        await closing?.close()
        guard op == token else { return }
        do { try await connect(host, peer, token: token) } catch {
            if op == token { failed(error, host, peer: peer) }
        }
    }

    /// Connects only now (the Host drops a connection idle for 10 s), pairs, saves the Mac, opens, lists.
    /// A failure leaves the screen on `.pairing` with a message.
    public func pair(code: String) async {
        // A second call while one is in flight would use up the code on the Host and save nothing.
        guard case let .pairing(host) = screen, pairingOp != pairSeq else { return }
        enterBusy()
        pairSeq += 1
        let token = pairSeq
        var expectedOp = op  // another user action (a `begin()`) supersedes this pairing; a sheet's own do not
        pairingOp = token
        defer { if pairingOp == token { pairingOp = nil }; leaveBusy() }
        let session: ClientSession
        do { session = try makeSession() } catch {
            message = Messages.storeFailed
            return
        }
        func alive() -> Bool { pairSeq == token && op == expectedOp }
        do {
            try await session.connect(to: host.endpoint)
            let peer = try await session.pair(code: code)
            guard alive() else { throw Superseded() }
            try withStore {
                for old in try store.hosts() where old.name == peer.name && old.key != peer.key { try store.remove(hostKey: old.key) }
                try store.save(host: peer)
            }
            try await session.open(host: peer, resume: false)
            guard alive() else { throw Superseded() }
            // The Mac that was open (if any) closes only now that this pairing worked; its reconnect loop and timers end with it.
            expectedOp = begin()
            let closing = teardown()
            target = nil
            games = []
            gameState = nil
            await closing?.close()
            guard alive() else { throw Superseded() }
            attach(session, host, peer, closingSheet: true)
            await listGames()
        } catch {
            await session.close()
            if alive() { failed(error, host, stay: true) }
        }
    }

    /// Closes the sheet and shows what is underneath: a session still open (opened before the pairing began), the Mac being
    /// regained or unreachable, else the home screen. It cancels nothing of the Mac's own work (`op` is untouched).
    public func cancelPairing() {
        guard case .pairing = screen else { return }
        pairSeq += 1
        message = nil
        pairingResult = nil
        defer {
            if resumeAfterSheet {
                resumeAfterSheet = false
                if link == nil, !sheetOpen { openTask = Task { [weak self] in await self?.foreground() } }
            }
        }
        if link != nil {
            problem = nil
            screen = playChosen && gameState.map { $0.run == .starting || $0.run == .running } == true ? .playing : .library
        } else if current != nil, retryTask != nil {
            problem = nil
            screen = .library
            message = Messages.connectionLost
        } else if let current, macState == .unreachable, let why = problem {
            screen = .library
            message = Messages.sentence(why, mac: current.name)
        } else if current != nil, macState == .connecting || macState == .looking {
            screen = .library
        } else {
            problem = nil
            goHome(nil)
        }
    }

    var sheetOpen: Bool { if case .pairing = screen { true } else { false } }

    /// The person edits the code after a refusal: the refusal's sentence and red state clear together.
    public func codeEdited() {
        guard case .pairing = screen else { return }
        message = nil
        problem = nil
        pairingResult = nil
    }

    /// Opens the last Mac again: discovery restarts, then the lookup and connect of `openLastMac`.
    public func retry() async {
        guard current != nil else { return }
        browser.restart()
        await openLastMac(token: begin())
    }

    /// Makes `row` the current Mac: a found one is connected as `choose` does (unpaired: `.pairing`); a paired one
    /// discovery does not list becomes current and unreachable.
    public func switchMac(_ row: MacRow) async {
        if let host = found.first(where: { Self.rowID($0) == row.id }) {
            await choose(host)
            return
        }
        guard let peer = peers.first(where: { Self.id(of: $0) == row.id }) else { return }
        let token = begin()
        let closing = teardown()
        target = nil
        await closing?.close()
        guard op == token else { return }
        chosenKey = peer.key
        show(peer)
        screen = .library
        markUnreachable(peer)
    }

    /// The Macs list: paired ones by name, then Macs found and not paired by name.
    public var macRows: [MacRow] {
        let running: String? = {
            guard playChosen, let s = gameState, s.run == .running || s.run == .starting, let id = s.titleID else { return nil }
            return games.first { $0.titleID == id }?.name
        }()
        var rows = peers.sorted { $0.name < $1.name }.map { peer -> MacRow in
            let host = found.first { Self.same(peer, $0) }
            let isCurrent = current?.key == peer.key
            return MacRow(id: Self.id(of: peer), name: host?.name ?? peer.name, paired: true,
                          reachable: host != nil || (isCurrent && macState == .connected), current: isCurrent,
                          playing: isCurrent ? running : nil)
        }
        rows += found.filter { host in !peers.contains { Self.same($0, host) } }.sorted { $0.name < $1.name }
            .map { MacRow(id: Self.rowID($0), name: $0.name, paired: false, reachable: true, current: false, playing: nil) }
        return rows
    }

    /// Lists the games again.
    public func refresh() async {
        guard let id = link?.id else { return }
        do {
            try await listGames(link: id, throwing: true)
            succeeded(link: id)
        } catch {
            callFailed(error, link: id)
        }
    }

    /// Closes any session as `disconnect()` does and deletes the identity and the paired Macs.
    public func resetStore() async {
        enterBusy()
        defer { leaveBusy() }
        await disconnect()
        do { try withStore { try store.reset() } } catch { message = Self.describe(error) }
        reloadPeers()
        chosenKey = nil
        current = nil
        hostName = nil
        games = []
        screen = .hosts
        lookingSince = Date()
    }

    /// Leaves play or the starting screen ("Disconnect", "Back to games"): the session closes (the Host pauses the game, or
    /// owes the pause while it prepares) and a library session to the same Mac opens (`.connecting`, then `.connected`, no
    /// sentence); only when that fails is the Mac unreachable with `cannotReach`. No Mac: as `disconnect()`.
    public func leave() async {
        playChosen = false  // the play is over now: a background meanwhile must not come back resuming
        playAsked = nil
        let token = begin()
        let closing = teardown()
        guard let target else {
            goHome(nil)
            await closing?.close()
            return
        }
        gameState = nil
        screen = .library
        macState = .connecting
        message = nil
        problem = nil
        await closing?.close()  // the Host sees this session end before the next one's hello
        guard op == token else { return }
        enterBusy()
        defer { leaveBusy() }
        switch await reopen(target, token: token, resume: false) {
        case .done, .stopped: break
        case .again:
            guard op == token else { return }
            self.target = nil
            gameState = nil
            markUnreachable(target.peer)
        }
    }

    /// Closes the session and opens none: the Mac's library, unreachable (first run with no paired Mac). `resetStore` and tests.
    func disconnect() async {
        _ = begin()
        let closing = teardown()
        goHome(nil)
        await closing?.close()
    }

    /// Closes the session as `leave()` does, but keeps the screen and remembers the Mac for `foreground()`.
    public func background() async {
        if sheetOpen { resumeAfterSheet = true }
        let card = endedReason
        _ = begin()
        if screen == .playing, let card { endedReason = card; refreshTrouble() }  // a card that was up stays up
        let closing = teardown()
        await closing?.close()
    }

    /// Opens a session to the Mac `background()` left, resuming when it was playing; the game state then picks the screen.
    /// A failure starts the retry loop of a lost connection. Discovery restarts while blocked, on first run or with the Mac unreachable.
    public func foreground() async {
        if discoveryMessage != nil || screen == .hosts || macState == .unreachable { browser.restart() }
        // A start that `background()` interrupted: no session, no target yet; the last Mac is opened as at launch.
        if link == nil, target == nil, current != nil, screen == .library { await openLastMac(token: begin()); return }
        guard link == nil, let target, screen == .library || screen == .playing else { return }
        enterBusy()
        defer { leaveBusy() }
        let card = endedReason
        let token = begin()
        if screen == .playing, let card { endedReason = card; refreshTrouble() }
        switch await reopen(target, token: token, resume: playChosen) {
        case .done, .stopped: break
        case .again:
            lostWhilePlaying()
            startRetry(target)
        }
    }

    /// Play lost its session (its link ended, or a reopen on return or after "Apply and reconnect" failed): the ended card
    /// shows at once with its reason and Reconnect, and stays until a session attaches, the loop gives up or the person acts.
    func lostWhilePlaying() {
        guard screen == .playing else { return }
        let game = games.first { $0.titleID == gameState?.titleID }?.name ?? Messages.theGame
        endedReason = Messages.sessionEnded(mac: hostName ?? Messages.theMac, game: game)
        refreshTrouble()
    }

    // MARK: sessions

    /// A new action: older work is dropped when it resumes; the retry loop and the quit timer stop.
    func begin() -> Int {
        op += 1
        mediaPathFailures = 0
        retryTask?.cancel()
        retryTask = nil
        reconnecting = false
        quitTask?.cancel()
        quitTask = nil
        quitAsked = false
        endedReason = nil
        refreshTrouble()
        return op
    }

    func enterBusy() { busyCount += 1; busy = true }
    func leaveBusy() { busyCount -= 1; busy = busyCount > 0 }

    /// Runs a store operation and records whether it failed (`storeFailed`).
    func withStore<T>(_ body: () throws -> T) throws -> T {
        do {
            let value = try body()
            storeFailed = false
            return value
        } catch {
            storeFailed = true
            throw error
        }
    }

    /// A call's error is shown only while the session it was made on is still open; `.closed` never
    /// (the session's end owns the message).
    func callFailed(_ error: Error, link id: Int) {
        guard link?.id == id, (error as? ClientError) != .closed else { return }
        message = Self.describe(error, mac: hostName ?? Messages.theMac)
    }

    func succeeded(link id: Int) { if link?.id == id { message = nil } }

    /// The `hello`'s bitrate wish (the Host's ceiling until a `liveSettings` replaces it).
    var helloBitrate: UInt32 { max(UInt32(clamping: min(max(settings.bitrateMbps, 1), 1000) * 1_000_000), RateController.floorBps) }

    func makeSession() throws -> ClientSession {
        connectedWith = ConnectionShape(width: settings.maxWidth, height: settings.maxHeight, fps: settings.maxFps)
        return ClientSession(identity: try withStore { try store.identity() }, name: deviceName, kind: kind, maxWidth: settings.maxWidth,
                      maxHeight: settings.maxHeight, maxFps: settings.maxFps,
                      bitrate: helloBitrate, silenceTimeout: silenceTimeout)
    }

    /// Connect, open, attach, list. Throws `Superseded` when a newer action took over meanwhile. `resume`: a resuming
    /// session (play picked up again) instead of a library one.
    func connect(_ host: FoundHost, _ peer: PairedPeer, token: Int, resume: Bool = false) async throws {
        let session = try makeSession()
        do {
            try await session.connect(to: host.endpoint)
            try await session.open(host: peer, resume: resume ? nil : false)
            guard op == token else { throw Superseded() }
        } catch {
            await session.close()
            throw error
        }
        // A Mac renamed on its network (a conflict suffix) is the same Mac: the stored name follows the browsed one.
        var peer = peer
        if peer.name != host.name {
            peer.name = host.name
            _ = try? withStore { try store.save(host: peer) }
        }
        attach(session, host, peer, plays: resume)
        await listGames()
    }

    /// A stored Mac is the browsed one by `id` (the key's fingerprint); by name only when the Host sends no `id`.
    static func same(_ peer: PairedPeer, _ host: FoundHost) -> Bool {
        guard let id = host.id else { return peer.name == host.name }
        return Identity.discoveryID(publicKey: peer.key) == id
    }

    enum Reopen { case done, stopped, again }

    /// One attempt to get back to `target`: `.stopped` for a refusal (shown) or a newer action, `.again` otherwise.
    func reopen(_ target: (host: FoundHost, peer: PairedPeer), token: Int, resume: Bool) async -> Reopen {
        do {
            try await connect(target.host, target.peer, token: token, resume: resume)
            return .done
        } catch where op != token || error is Superseded {
            return .stopped
        } catch let ClientError.refused(r) {
            if r == .unpaired {
                forget(target.peer)
                screen = .pairing(target.host)
                message = Messages.refusal(r, mac: target.peer.name)
            } else if screen == .playing {
                // During play a refusal (another device plays, another version) ends on the card at once, not retried; its
                // Reconnect tries once more, Back to games leaves
                endedReason = Messages.refusal(r, mac: target.peer.name)
                reconnecting = false
                refreshTrouble()
            } else {
                goHome(.refused(r), mac: target.peer.name)
            }
            return .stopped
        } catch {
            return .again
        }
    }

    /// `connectionLost`, then connect, open, list every `retryInterval` until it works or is refused; resuming when the lost
    /// session was playing.
    func startRetry(_ target: (host: FoundHost, peer: PairedPeer)) {
        let resume = playChosen
        if !sheetOpen { message = Messages.connectionLost }  // under a pairing sheet the sentence waits for `cancelPairing`
        reconnecting = true
        macState = .connecting
        retryTask?.cancel()
        let token = op
        let interval = UInt64(retryInterval * 1e9)
        let limitNs = UInt64(retryLimit * 1e9)
        let startNs = DispatchTime.now().uptimeNanoseconds
        let expired: @Sendable () -> Bool = { DispatchTime.now().uptimeNanoseconds - startNs >= limitNs }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self, self.op == token else { return }
                if expired() { self.giveUp(token: token); return }
                if await self.reopen(target, token: token, resume: resume) != .again {
                    if self.op == token { self.retryTask = nil }
                    return
                }
                // An attempt can itself take seconds: the limit is checked again before the next sleep.
                if self.op == token, expired() { self.giveUp(token: token); return }
            }
        }
    }

    /// No answer for the whole limit: the Macs list, with the reason.
    func giveUp(token: Int) {
        guard op == token else { return }
        retryTask = nil
        guard sheetOpen else { goHome(.stoppedAnswering); return }
        endedReason = nil
        refreshTrouble()
        reconnecting = false  // the sheet stays; `cancelPairing` shows the unreachable library underneath
        target = nil
        gameState = nil
        macState = .unreachable
        problem = .stoppedAnswering
    }

    /// Shows a failed call: an unpaired refusal forgets `peer` and opens `.pairing`; `stay` keeps the pairing screen for
    /// other errors (a wrong code; with a session still open, a refusal too); everything else goes home (a paired Mac's
    /// library, unreachable, else first run).
    func failed(_ error: Error, _ host: FoundHost, peer: PairedPeer? = nil, stay: Bool = false) {
        if error is Superseded { return }
        let text = Self.describe(error, mac: host.name)
        if case let .pairing(result)? = error as? ClientError { pairingResult = result }
        if case .refused(.unpaired)? = error as? ClientError {
            if let peer { forget(peer) }
            screen = .pairing(host)
            message = text
        } else if stay, !Self.isRefusal(error) || link != nil {
            message = text
        } else {
            goHome(Self.problem(for: error, mac: host.name), mac: host.name)
        }
    }

    /// The Mac no longer knows this device: it leaves the store, and the current Mac when it was that one.
    func forget(_ peer: PairedPeer) {
        _ = try? withStore { try store.remove(hostKey: peer.key) }
        reloadPeers()
        if current?.key == peer.key { current = nil; hostName = nil }
        if chosenKey == peer.key { chosenKey = nil }
        reconnecting = false
        target = nil
        games = []
        gameState = nil
    }

    static func isRefusal(_ error: Error) -> Bool {
        if case .refused? = error as? ClientError { true } else { false }
    }

    /// The screen after a Mac is lost or refused: the library of a paired Mac, unreachable, with its last known games;
    /// the first-run screen when none is paired. The message is set last.
    func goHome(_ why: Messages.Problem?, mac: String? = nil) {
        reloadPeers()
        target = nil
        playChosen = false
        playAsked = nil
        endedReason = nil
        refreshTrouble()
        reconnecting = false
        gameState = nil
        if let peer = pickCurrent() {
            show(peer)
            screen = .library
            macState = .unreachable
        } else {
            current = nil
            hostName = nil
            games = []
            screen = .hosts
            lookingSince = lookingSince ?? Date()
        }
        problem = why
        message = why.map { Messages.sentence($0, mac: mac ?? hostName ?? Messages.theMac) }
    }

    func reloadPeers() { peers = (try? withStore { try store.hosts() }) ?? [] }

    /// The last Mac used when it is still paired, else the first paired one.
    func pickCurrent() -> PairedPeer? {
        let last = try? store.lastHostKey()  // not `withStore`: a success here must not clear `storeFailed`
        return peers.first { $0.key == chosenKey } ?? peers.first { $0.key == last } ?? peers.first
    }

    /// Makes `peer` the current Mac with its cached games.
    func show(_ peer: PairedPeer) {
        if current?.key != peer.key { dropOptions() }  // another Mac's options never show under this one
        current = peer
        hostName = peer.name
        lookingSince = nil
        games = cache?.games(for: peer.key) ?? []
        gamesListed = false
        listFailed = false
        lastPlayedTitle = cache?.lastPlayed(for: peer.key)
        wantArt()
    }

    /// A Mac's id in the list: the discovery ID when the Host sends one, else its name.
    static func rowID(_ host: FoundHost) -> String { host.id ?? host.name }
    static func id(of peer: PairedPeer) -> String { Identity.discoveryID(publicKey: peer.key) }

    /// The library of the last Mac with its last known games while the browser lists it; after `lookupLimit` without it
    /// `.unreachable` with `cannotReach`. Connects in the background; failures go through `failed`.
    func openLastMac(token: Int) async {
        guard let peer = current, op == token else { return }
        macState = .looking
        let end = Date().addingTimeInterval(lookupLimit)
        var host: FoundHost?
        while op == token {
            host = found.first { Self.same(peer, $0) }
            if host != nil || Date() >= end { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard op == token else { return }
        guard let host else {
            markUnreachable(peer)
            return
        }
        macState = .connecting
        enterBusy()
        defer { leaveBusy() }
        do { try await connect(host, peer, token: token) } catch {
            if op == token { failed(error, host, peer: peer) }
        }
    }

    static func describe(_ error: Error, mac: String = Messages.theMac) -> String {
        Messages.sentence(problem(for: error, mac: mac), mac: mac)
    }

    static func problem(for error: Error, mac: String) -> Messages.Problem {
        switch error {
        case let ClientError.refused(r): .refused(r)
        case let ClientError.pairing(r): .other(Messages.pairing(r, mac: mac))
        case PairingError.hostProofInvalid: .codeDidNotMatch
        case is ClientStoreError: .storeFailed
        default: .didNotAnswer
        }
    }

    /// The Mac is current but not answering: its library stays, with `cannotReach`.
    func markUnreachable(_ peer: PairedPeer) {
        macState = .unreachable
        problem = .cannotReach
        message = Messages.cannotReach(peer.name)
    }

    /// Stops playing and every task of the open session; returns the session for the caller to close.
    func teardown() -> ClientSession? {
        guard let l = link else { return nil }
        stopPlaying(l)
        l.cancel()
        link = nil
        stalled = false
        showsReconnecting = false
        overlayTask?.cancel()
        lastInputs = [:]
        preparing = nil
        preparingSince = nil
        dropArtRequests()
        dropOptions()
        connectedWith = nil
        return l.session
    }

    /// The session's states move the screen; its end starts the retry loop.
    /// Opening is the success of the action: the message clears before the first state can set one.
    /// `plays`: the session was opened resuming (play picked up again); a library session plays only once a game is chosen.
    func attach(_ session: ClientSession, _ host: FoundHost, _ peer: PairedPeer, plays: Bool = false, closingSheet: Bool = false) {
        if closingSheet || !sheetOpen {
            message = nil
            problem = nil
            pairingResult = nil
        }
        reconnecting = false
        resumeAfterSheet = false
        endedReason = nil
        refreshTrouble()
        playChosen = plays
        playAsked = nil
        launchAsked = nil  // an ask of an earlier session has no answer coming on this one
        if closingSheet, sheetOpen { screen = .library }  // the sheet's pairing worked; the first state picks the screen
        nextLinkID += 1
        let id = nextLinkID
        var l = Link(id: id, session: session, audio: sound ? AudioOutput(bufferMs: settings.audioBufferMs, automatic: settings.audioBufferAuto) : nil)
        let states = session.states
        l.tasks.append(Task { [weak self, weak session] in
            for await state in states {
                guard let self else { return }
                self.apply(state, link: id)
                await self.listGames(link: id)
            }
            let end = await session?.end
            self?.ended(link: id, end)
        })
        let stalls = session.stalls
        l.tasks.append(Task { [weak self] in
            for await on in stalls { self?.setStalled(on, link: id) }
        })
        let arts = session.arts
        l.tasks.append(Task { [weak self] in
            for await chunk in arts { self?.artChunk(chunk, link: id) }
        })
        let optionReplies = session.optionReplies
        l.tasks.append(Task { [weak self] in
            for await o in optionReplies { self?.optionsReply(o, link: id) }
        })
        let optionRefusals = session.optionRefusals
        l.tasks.append(Task { [weak self] in
            for await _ in optionRefusals { self?.optionsRefused(link: id) }
        })
        l.tasks += Self.pumps(l, sink)
        l.gate.soundOn = settings.playSound
        link = l
        stalled = false
        showsReconnecting = false
        overlayTask?.cancel()
        lastInputs = [:]
        target = (host, peer)
        hostName = peer.name
        macState = .connected
        lookingSince = nil
        _ = try? store.setLast(hostKey: peer.key)  // only a connect that succeeded sets the last Mac
        chosenKey = nil
        reloadPeers()
        current = peer
        applyLive()  // the Host learns the saved ceiling and numbers level (a new session starts with neither)
    }

    /// The screen rule: `starting` / `running` -> `.playing` once the session plays (`playChosen`), else `.library`;
    /// `idle` / `paused` -> `.library`.
    func apply(_ state: GameState, link id: Int) {
        guard let l = link, l.id == id else { return }
        let wasPlaying = screen == .playing
        let sheet: Bool = if case .pairing = screen { true } else { false }  // a pairing sheet opened over this session stays
        gameState = state
        let live = state.run == .starting || state.run == .running
        // The game this session played is gone: it is a library session now (a later background or lost connection reopens
        // it as one), and notes of a launch or resume that never got an answer must not relabel what the Host says next.
        if state.run == .idle, playChosen {
            playChosen = false
            playAsked = nil
            launchAsked = nil
        }
        // The Host's answer to `launch` / `resume`: that game starting or running confirms the play; a reason refuses it, and
        // so does `idle` (no game is left to play).
        if let ask = playAsked {
            if live, ask.isEmpty || state.titleID == ask {
                playChosen = true
                playAsked = nil
            } else if state.run == .idle || !(state.reason ?? "").isEmpty {
                playAsked = nil
            }
        }
        if live, playChosen, let id = state.titleID { playedOnThisMac(id) }
        if live, playChosen {
            if !sheet { screen = .playing }
            startPlaying(l)
        } else {
            stopPlaying(l)
            if !sheet { screen = .library }
        }
        notePreparing(state)
        noteRender(state)
        // A launch the Host answered with another state: its reason says why ("<game> is running").
        // Kept until its answer: the launched game's own state, or one with a reason (a preparing game's progress is neither).
        guard let asked = launchAsked else { return idleRule(state, wasPlaying: wasPlaying) }
        let reason = state.reason ?? ""
        guard !reason.isEmpty || state.titleID == asked else { return idleRule(state, wasPlaying: wasPlaying) }
        launchAsked = nil
        if !reason.isEmpty, !(live && playChosen) {
            message = Messages.launchReply(reason)
            return
        }
        idleRule(state, wasPlaying: wasPlaying)
    }

    /// `idle`: a quit that was asked ends quietly; one that was not, while playing, says why.
    private func idleRule(_ state: GameState, wasPlaying: Bool) {
        guard state.run == .idle else { return }
        if quitAsked {
            quitAsked = false
            quitTask?.cancel()
            quitTask = nil
            message = nil
        } else if wasPlaying {
            message = Messages.ended(reason: state.reason)
        }
    }

    /// The session ended by itself: lost (`hostClosed`, `silence`, `mediaPathSilent`) while with a Mac -> the retry
    /// loop; the third `mediaPathSilent` in a row stops it with a plain message -> .claude/client.md § model
    func ended(link id: Int, _ end: SessionEnd?) {
        guard link?.id == id else { return }
        _ = teardown()  // already shut down: nothing to close
        // Another device took the Mac from this library session: no attempt of its own (it would take it back); Retry does.
        if case let .takenOver(by)? = end {
            mediaPathFailures = 0
            goHome(.inUse(device: by))
            return
        }
        mediaPathFailures = end == .mediaPathSilent ? mediaPathFailures + 1 : 0
        if mediaPathFailures >= Self.mediaPathAttempts {
            mediaPathFailures = 0
            goHome(.mediaPathBlocked)
            return
        }
        guard let target, let end, Self.lostEnds.contains(end), screen == .library || screen == .playing || sheetOpen else {
            goHome(.didNotAnswer)
            return
        }
        lostWhilePlaying()
        startRetry(target)
    }

    /// The newest reply wins: a list asked earlier never overwrites one asked later.
    func listGames(link id: Int? = nil, throwing: Bool = false) async throws {
        guard let l = link, id == nil || l.id == id else { return }
        listAsked += 1
        let asked = listAsked
        do {
            let entries = try await l.session.list()
            guard link?.id == l.id, asked > listShown else { return }
            listShown = asked
            gamesListed = true
            listFailed = false
            games = entries
            if let key = current?.key { cache?.save(entries, for: key) }
            wantArt()
        } catch {
            // A session that ended is reported by `ended`; only `refresh()` sees the error, and only for its own session.
            if link?.id == l.id, asked > listShown { listFailed = true }
            if throwing, link?.id == l.id { throw error }
        }
    }

    func listGames(link id: Int? = nil) async { try? await listGames(link: id, throwing: false) }
}
