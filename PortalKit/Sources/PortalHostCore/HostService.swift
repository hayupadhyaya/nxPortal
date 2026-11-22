#if os(macOS)
import CryptoKit
import Foundation
import Network
import PortalKit

public struct HostConfig: Sendable {
    public var name: String, storeURL: URL, libraryRoots: [URL]
    public var launcher: any GameLaunching, power: any PowerHolding
    /// Port 0 = any.
    public var advertise: Bool, port: UInt16
    /// Seconds an unadmitted connection may go without a valid step (tests shorten it).
    public var unadmittedTimeout: TimeInterval = 10
    /// The clock every session timer reads (silence, unadmitted links, game start and quit, session length); a test drives it.
    public var clock: @Sendable () -> Date = HostConfig.monotonicNow
    /// The pairing store lives here (keys `host.identity`, `host.peers`) instead of the file at `storeURL`, which is then not read or written.
    public var secrets: (any SecretStoring)?
    /// Variables added to the environment of a game launched for this title ID. The Host's own variables always win.
    public var gameEnvironment: @Sendable (_ titleID: String) -> [String: String] = { _ in [:] }
    /// The per-game choices of paired devices are kept in this file (0600, in a 0700 folder); nil = in memory only, so a test or a
    /// run that must not touch the person's folder never does -> .claude/host.md § options
    public var optionsURL: URL?
    /// A game's own saved choice for a variable (`launcher.<env>` in its bundle ID's preferences domain), shown as the current value
    /// when the app has no choice for it. Tests give their own; the default reads the real domain.
    public var savedChoice: @Sendable (_ bundleID: String, _ env: String) -> String? = { bundleID, env in
        // Text only: the runtime ignores a saved choice that is not a string (`frontends.md` § Saved choices), so a number or a
        // boolean there is not what a start would use and is not shown as the current value.
        CFPreferencesCopyAppValue("launcher.\(env)" as CFString, bundleID as CFString).flatMap { HostConfig.preferenceText($0) }
    }
    /// A saved choice as text: a string, nothing else.
    public static func preferenceText(_ value: Any) -> String? { value as? String }
    /// Which variables a device may set (and a game's list may have a row for); the default is the runtime's player settings
    /// (`PlayerOptions`). Not public API: reached only with `@_spi(Testing) import PortalHostCore` (tests with made-up variables give a wider one) -> .claude/host.md § options
    @_spi(Testing) public var settableOption: @Sendable (String) -> Bool = PlayerOptions.isSettable
    /// Tests: changes the answer of an options message on its way out, or drops it (nil): a Host stand-in that sends what no
    /// Host would, or nothing.
    @_spi(Testing) public var optionsAnswerHook: (@Sendable (GameOptions) -> GameOptions?)?
    /// The video bitrate (bit/s) for a client whose `hello` carries none; `maxBitrate` still caps it.
    public var defaultBitrate: UInt32 = HostDefaults.bitrate
    /// Appended to the library scan (the fake game).
    public var extraGames: [GameApp] = []
    /// How long a live game process may take to connect (a first launch is scanned by macOS first).
    public var startTimeout: TimeInterval = 600
    /// Highest video bitrate (bit/s) a client may ask for.
    public var maxBitrate: UInt32 = HostDefaults.maxBitrate
    /// Tests that run several Hosts in one process give each its own tap socket; nil = `HostDefaults.socketPath(instance:)` with a process-wide instance number.
    public var tapSocketPath: String?
    /// Each video frame's datagrams are spread over about this many ms (frames of 8 datagrams or fewer leave at once); 0 = all at once.
    public static let defaultPaceMs = 4.0
    public var paceMs = HostConfig.defaultPaceMs
    /// No frame leaves faster than this multiple of the video bitrate (a large frame takes longer; the frames behind it wait).
    public var pacePeak = 3.0
    /// Seconds without any packet before the live client is let go (tests shorten it).
    public var silenceTimeout = HostSessionModel.defaultSilenceTimeout
    /// The UDP port `welcome` tells the client, when something stands in front of the media socket (a development
    /// shaper); nil = the media socket's own port.
    public var advertisedMediaPort: UInt16?
    /// Makes the sampler of the Mac's load, once for each stretch of a live session at the panel's "full" level.
    public var loadSampler: @Sendable () -> any LoadSampling = { MacLoadSampler() }

    public init(name: String, storeURL: URL, libraryRoots: [URL], launcher: any GameLaunching, power: any PowerHolding,
                advertise: Bool, port: UInt16, extraGames: [GameApp] = [],
                startTimeout: TimeInterval = 600, maxBitrate: UInt32 = HostDefaults.maxBitrate) {
        self.maxBitrate = maxBitrate
        self.name = name; self.storeURL = storeURL; self.libraryRoots = libraryRoots
        self.launcher = launcher; self.power = power; self.advertise = advertise; self.port = port
        self.extraGames = extraGames; self.startTimeout = startTimeout
    }
}

extension HostConfig {
    /// Uptime (it does not step with the wall clock) mapped onto `Date`; only differences mean anything.
    public static func monotonicNow() -> Date {
        Date(timeIntervalSinceReferenceDate: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9)
    }
}

public enum HostStatus: Equatable, Sendable {
    /// `pairing.until`: the wall-clock end of the code's window, for display only (`tick` decides the expiry).
    case idle, pairing(code: String, until: Date), live(device: String, tag: String, game: String?), paused(game: String)
    /// The service is not serving (it could not start, or its listener failed); text for people, no address.
    case failed(String)
}

extension HostStatus {
    /// The status as a log line: a device is its tag, never its name; `showCode: false` leaves a pairing code out
    /// -> .claude/host.md § log
    public func logText(showCode: Bool) -> String {
        switch self {
        case .idle: "status: idle"
        case let .pairing(code, _): showCode ? "status: pairing \(code)" : "status: pairing"
        case let .live(_, tag, game): "status: live \(tag)" + (game.map { " playing \($0)" } ?? "")
        case let .paused(game): "status: paused \(game)"
        case let .failed(text): "status: failed (\(text))"
        }
    }
}

public enum HostServiceError: Error, Equatable { case system(String, Int32), alreadyStarted, stopped }

/// What a person reads: one sentence per case, no call name, number or path -> .claude/host.md § service
extension HostServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .system: "The Host could not set up its network connection."
        case .alreadyStarted: "The Host is already running."
        case .stopped: "The Host is not running."
        }
    }
}

/// Pairing, control, media relay and session rules over the PortalKit pieces -> .claude/host.md § service
public actor HostService {
    /// One control connection. `session` exists from `welcome` on; `admitted` from a `ready` that opened.
    struct Link {
        let connection: NWConnection
        /// Open, or the last valid step before admission (`pairStart`, pairing `.ok`, `hello` accepted).
        var openedAt: Date
        var framer = ControlFramer()
        var session: Session?
        var admitted = false
        /// `artRequest`s not yet answered, oldest first (at most `maxArtQueue`); `artBusy` while its worker runs.
        var artQueue: [ArtAsk] = []
        var artBusy = false
    }

    struct Session {
        /// Replaced at admission by what the device's hello brought, once it has proved its key.
        var peer: PairedPeer
        let hello: Hello
        let sessionID: UInt32
        var controlSealer: StreamSealer
        var controlOpener: StreamOpener
        var mediaSealer: DatagramSealer
        var mediaOpener: DatagramOpener
        /// Source of the newest datagram that opened.
        var address: UDPAddress?
        var audioSeq: UInt32 = 0
        var lastInputSeq: UInt32?
        /// The newest `rate`, clamped to `[1 Mbit/s, the ceiling]`; nil until the first (the hello's wish then).
        var rateBps: UInt32?
        /// The newest `liveSettings` ceiling (clamped), replacing the hello's wish as the ceiling; nil until one arrives.
        var ceilingBps: UInt32?
        /// The device's numbers panel level (`liveSettings`); nil until told.
        var panel: PanelLevel?
        var counters: SessionCounters
        /// The control connection's local endpoint, captured when the session went live.
        var controlLocal: NWEndpoint?
    }

    struct Pairing { var host: PairingHost; let code: String; let startedAt: Date; var owner: Int? }

    struct Game {
        let app: GameApp
        let generation: Int
        let launchedAt: Date
        var handle: (any RunningGame)?
        var connected = false
        var quitAt: Date?
        var terminating = false
        /// The newest `prepare` (the game prepares before its first frame), and when its phase began.
        var prepare: GamePrepare?
        var phaseStartedAt: Date?
        /// What the device is told about the preparation -> `PreparingTracker`.
        var tracker = PreparingTracker()
        /// The live session ended while the game prepared: the pause is owed and goes out when the preparation ends.
        var pauseDeferred = false
        /// The size of the game's newest picture against the device's cap; nil until its first frame.
        var render: RenderSize?
    }

    public nonisolated let status: AsyncStream<HostStatus>
    let statusOut: AsyncStream<HostStatus>.Continuation
    /// One report per live session that ends -> .claude/host.md § session-end
    public nonisolated let sessionEnds: AsyncStream<SessionEndReport>
    let sessionEndsOut: AsyncStream<SessionEndReport>.Continuation
    /// One line per noteworthy game event (a preparation phase's start and end, a tap message of an unknown type)
    /// -> .claude/host.md § service
    public nonisolated let notes: AsyncStream<String>
    let notesOut: AsyncStream<String>.Continuation
    let config: HostConfig
    let store: PairingStore
    /// The per-game choices of paired devices (`config.optionsURL`) -> `HostService+Options.swift`
    let optionsStore: GameOptionsStore
    var library: GameLibrary
    let tap: TapServer
    let tapSocketPath: String
    let media = MediaSocket()
    let sender: MediaSender
    let control = ControlListener()

    var model = HostSessionModel()
    var links: [Int: Link] = [:]
    /// The admitted connection; only its end reaches the model.
    var liveLink: Int?
    var pairing: Pairing?
    var game: Game?
    var generation = 0
    var lastHello: Hello?
    /// The `Hello` of the session that last configured the game as a player: the size, frame rate and wish the game runs
    /// at while a library session (which never configures it) is live.
    var playerHello: Hello?
    var lastKeyframe = Date.distantPast
    var lastRefresh = Date.distantPast
    /// Frame -> token of the last 2 s, and the acknowledgements passed to the game -> .claude/host.md § ltr
    var acks = LtrAcks()
    /// Frame sizes by kind (ordinary, key, repair) since the service started (the exit line).
    var sizes = FrameSizes()
    /// Tap messages of an unknown type, by type, since the service started.
    var skippedTap: [UInt8: Int] = [:]
    /// Video fragments of the last 0.5 s, for `nack` -> .claude/host.md § service
    var resends = ResendStore()
    /// Video frames the game delivered in the live session (`hostStats`), and when `hostStats` last went out.
    var framesFromGame: UInt32 = 0
    var lastHostStats = Date.distantPast
    /// The Mac's load while a live session shows "full": the sampler lives in its own actor (a read never runs on this one),
    /// `loadFrames` collects the game's frame times, `loadGeneration` drops a reading that finishes after the stretch ended
    /// -> .claude/host.md § load
    var loadRunner: LoadRunner?
    var loadFrames = FrameClock()
    var lastLoadAt = Date.distantPast
    /// The game's frame rate for the menu's second line, measured from the frames delivered to a playing device (whatever the
    /// panel shows): `measuredFps` (whole frames a second) is read for 3 s after its measure, then it is unknown.
    var fpsClock = FrameClock()
    var fpsTakenNs: UInt64 = 0, fpsLastFrameNs: UInt64 = 0, fpsMeasuredNs: UInt64 = 0
    var measuredFps: Int?
    var loadInFlight = false
    var loadGeneration = 0
    var videoBitrate: UInt32
    /// A client `rate` not yet passed to the game (the newest replaces it), and when a config last went to it -> .claude/host.md § service
    var pendingRate: UInt32?
    var lastConfigNs: UInt64 = 0
    /// The `preparing` the live device was last told, and when a progress-only change last went out (at most 2 a second).
    var sentPreparing: Preparing?
    var lastPreparingSendNs: UInt64 = 0
    var awake = false
    var udpPort: UInt16 = 0
    var tasks: [Task<Void, Never>] = []
    var started = false
    var stopped = false
    var lastStatus: HostStatus?
    var lifecycle = LifecycleState()
    /// Icons by title ID, the only copy on the Host -> .claude/host.md § library
    var artwork: [String: KeptArt] = [:]
    /// Transfers sending now, the most at once since start (tests), and the transfers waiting for a slot.
    var artTransfers = 0
    var artTransfersPeak = 0
    var artSlotWaiters: [CheckedContinuation<Void, Never>] = []
    /// `art` messages the connections have taken since start (tests).
    var artMessagesTaken = 0

    public init(config: HostConfig) throws {
        self.config = config
        videoBitrate = config.defaultBitrate
        model = HostSessionModel(silenceTimeout: config.silenceTimeout)
        tapSocketPath = try config.tapSocketPath ?? HostDefaults.socketPath(instance: Self.nextInstance())
        tap = TapServer(socketPath: tapSocketPath, requirePrivateFolder: config.tapSocketPath == nil)
        if let secrets = config.secrets { store = try PairingStore(secrets: secrets) } else { store = try PairingStore(fileURL: config.storeURL) }
        sender = MediaSender(socket: media, paceMs: config.paceMs, pacePeak: config.pacePeak)
        optionsStore = GameOptionsStore(fileURL: config.optionsURL)
        library = GameLibrary(roots: config.libraryRoots)
        (status, statusOut) = AsyncStream.makeStream(of: HostStatus.self, bufferingPolicy: .unbounded)
        (sessionEnds, sessionEndsOut) = AsyncStream.makeStream(of: SessionEndReport.self, bufferingPolicy: .unbounded)
        (notes, notesOut) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    /// The media socket's own UDP port (0 before `start()`); `welcome` tells the client `config.advertisedMediaPort` instead when set.
    public var mediaPort: UInt16 { udpPort }

    /// The TCP port. Advertises `_nxportal._tcp` when `config.advertise`. A start that throws has released everything.
    public func start() async throws -> UInt16 {
        guard !started else { throw HostServiceError.alreadyStarted }
        started = true
        do { return try await bringUp() } catch {
            if !stopped { await startFailed(error) }  // a stop() that landed during start() has run the teardown already
            throw error
        }
    }

    private func bringUp() async throws -> UInt16 {
        try await tap.start()
        await lifecycle.startHold?()
        // A stop() between two awaits has run the teardown: open nothing after it -> .claude/host.md § service
        guard !stopped else { throw CancellationError() }
        udpPort = try media.start()
        guard !stopped else { throw CancellationError() }
        let port = try await control.start(port: config.port, serviceName: config.advertise ? config.name : nil,
                                           txt: ["id": discoveryID])
        guard !stopped else { control.stop(); throw CancellationError() }  // idempotent: the listener is closed whichever side won the race
        let control = control, media = media, tap = tap
        // Not cancelled by stop(): it drains to the finished stream, so a late `.opened` is still cancelled.
        _ = Task { for await e in control.events { await self.handle(e) } }
        tasks = [
            Task { for await d in media.datagrams { self.handle(d) } },
            Task { for await e in tap.events { self.handle(e) } },
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.tick()
                }
            },
        ]
        publishStatus()
        return port
    }

    /// Closes everything and ends the game; idempotent.
    public func stop() async { await shutdown() }

    /// A new code; replaces any earlier one. After `stop()`: throws `HostServiceError.stopped` and sets nothing.
    public func beginPairing() throws -> String {
        guard !stopped else { throw HostServiceError.stopped }
        var rng = SystemRandomNumberGenerator()
        let code = PairingCode.generate(using: &rng)
        let now = Date()  // wall time: pairing window (shown to a person, and the code's lifetime)
        pairing = Pairing(host: PairingHost(identity: store.identity, name: config.name, code: code, startedAt: now),
                          code: code, startedAt: now, owner: nil)
        publishStatus()
        return code
    }

    // MARK: control

    private func handle(_ event: ControlEvent) async {
        guard !stopped else {
            if case let .opened(_, connection) = event { connection.cancel() }
            return
        }
        switch event {
        case let .opened(id, connection):
            // Above the cap a new connection is refused at once -> .claude/host.md § service
            guard links.values.filter({ !$0.admitted }).count < Self.maxUnadmitted else { return connection.cancel() }
            links[id] = Link(connection: connection, openedAt: self.now())
        case let .data(id, bytes):
            guard links[id] != nil else { return }
            let payloads: [Data]
            do { payloads = try links[id]!.framer.push(bytes) } catch { return end(id, by: .controlError) }
            for p in payloads {
                guard links[id] != nil else { return }
                await frame(id, p)
            }
        case let .closed(id, failed):
            end(id, by: failed ? .controlError : .clientClosed)
        case let .failed(error):
            listenerFailed(error)
        }
    }

    /// Clear before `welcome`, sealed after; anything that does not open or decode ends the connection.
    private func frame(_ id: Int, _ payload: Data) async {
        guard links[id]?.session != nil else {
            guard let m = try? ControlMessage(decoding: payload) else { return end(id, by: .controlError) }
            return clear(id, m)
        }
        guard let json = try? links[id]!.session!.controlOpener.open(payload) else { return end(id, by: .controlError) }
        let m: ControlMessage
        do { m = try ControlMessage(decoding: json) } catch WireError.refused {
            // An options message over its limits (`OptionLimits`) is ignored, the session goes on; before admission nothing but
            // `ready` is allowed, so it ends the connection like any other message there.
            guard links[id]!.admitted else { return end(id, by: .controlError) }
            model.packetReceived(at: self.now())
            return
        } catch { return end(id, by: .controlError) }
        guard links[id]!.admitted else { return m == .ready ? admit(id) : end(id, by: .controlError) }
        model.packetReceived(at: self.now())
        switch m {
        case .listRequest: send(id, .list(await entries()))
        case let .artRequest(titleID, hash): askArt(id, ArtAsk(titleID: titleID, hash: hash))
        case let .liveSettings(live): applyLive(id, live)
        case let .optionsRequest(titleID): await optionsRequested(id, titleID: titleID)
        case let .setOption(titleID, env, value): await optionSet(id, titleID: titleID, env: env, value: value)
        case let .resetOptions(titleID): await optionsReset(id, titleID: titleID)
        case let .launch(titleID): await launch(titleID, from: id)
        case .resume: play()
        case .quitGame: quitGame()
        case .bye: end(id, by: .clientClosed)
        default: break
        }
    }

    private func clear(_ id: Int, _ m: ControlMessage) {
        switch m {
        case let .pairStart(start):
            guard var p = pairing else { return send(id, .pairResult(.expired)) }
            guard let challenge = try? p.host.challenge(for: start) else { return end(id, by: .controlError) }
            p.owner = id
            pairing = p
            links[id]?.openedAt = self.now()
            send(id, .pairChallenge(challenge))
        case let .pairProof(proof):
            guard var p = pairing, p.owner == id else { return send(id, .pairResult(.expired)) }
            let result = p.host.verify(proof: proof, at: Date())  // wall time: pairing window
            switch result {
            case .ok:
                guard let peer = p.host.paired, (try? store.add(peer)) != nil else { return end(id, by: .controlError) }
                pairing = nil
                links[id]?.openedAt = self.now()
            case .locked, .expired: pairing = nil
            case .wrongCode: pairing = p
            }
            send(id, .pairResult(result))
            publishStatus()
        case let .hello(h):
            hello(id, h)
        default:
            end(id, by: .controlError)
        }
    }

    /// Version, then paired, then busy; otherwise `welcome` in the clear and sealed from then on.
    private func hello(_ id: Int, _ h: Hello) {
        if h.version != ProtocolVersion.network { return refuse(id, .version(host: ProtocolVersion.network)) }
        guard let peer = store.peers.first(where: { $0.key == h.clientKey }) else { return refuse(id, .unpaired) }
        // Busy only while the live session plays: a library session gives way at admission -> .claude/host.md § service
        if let live = liveLink, let other = links[live]?.session?.peer, other.key != h.clientKey, model.playing {
            return refuse(id, .busy(device: shownName(of: other.key)))
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let keys = try? SessionKeys.derive(role: .host, identity: store.identity, ephemeral: ephemeral,
                                                 peerKey: h.clientKey, peerEphemeral: h.ephemeral) else { return end(id, by: .controlError) }
        let sessionID = newSessionID()
        send(id, .welcome(Welcome(ephemeral: ephemeral.publicKey.rawRepresentation, udpPort: config.advertisedMediaPort ?? udpPort, sessionID: sessionID)))
        links[id]?.openedAt = self.now()
        var session = Session(
            peer: peer, hello: h, sessionID: sessionID,
            controlSealer: StreamSealer(key: keys.hostToClientControl), controlOpener: StreamOpener(key: keys.clientToHostControl),
            mediaSealer: DatagramSealer(key: keys.hostToClientMedia, sessionID: sessionID),
            mediaOpener: DatagramOpener(key: keys.clientToHostMedia, sessionID: sessionID),
            counters: SessionCounters(welcomedAt: self.now()))
        // The start rate is the session's rate from admission, clamped as a `rate` -> .claude/host.md § service
        let most = ceiling(of: session)
        session.rateBps = h.startBps.map { min(max($0, HostDefaults.minBitrate), most) }
        links[id]?.session = session
    }

    /// The name and kind a `hello` changes (cleaned), nil when it changes none. Applied only at admission: the hello is unsealed
    /// and carries a public key, so until the first sealed frame opens it proves nothing.
    private func knownDetails(_ peer: PairedPeer, from h: Hello) -> (name: String?, kind: DeviceKind?)? {
        let name = h.name.flatMap(DeviceName.clean).flatMap { $0 == peer.name ? nil : $0 }
        let kind = h.kind == peer.kind ? nil : h.kind
        return name == nil && kind == nil ? nil : (name, kind)
    }

    /// The client is authenticated: its first sealed frame (`ready`) opened.
    private func admit(_ id: Int) {
        guard var s = links[id]?.session else { return }
        // The device has proved its key: now what its hello claimed (cleaned again, never trusted from the wire) is kept, before
        // the model admits, so the status line and the sentences other devices get use it. A store that cannot write keeps the
        // old name and the session goes on -> .claude/host.md § pairing-store
        if let kept = knownDetails(s.peer, from: s.hello), (try? store.update(key: s.peer.key, name: kept.name, kind: kept.kind)) != nil,
           let fresh = store.peers.first(where: { $0.key == s.peer.key }) {
            s.peer = fresh
            links[id]?.session?.peer = fresh
        }
        let (admission, actions) = model.admit(device: s.peer.key, name: shownName(of: s.peer.key), resume: s.hello.resume ?? true, gameExists: game != nil, at: self.now())
        if case .busy = admission {
            send(id, .bye())
            return end(id, afterSend: true, by: .controlError)
        }
        links[id]?.admitted = true
        links[id]?.session?.counters.admittedAt = self.now()
        let controlLocal = links[id]?.connection.currentPath?.localEndpoint  // a closed connection has no path
        links[id]?.session?.controlLocal = controlLocal
        let old = liveLink
        if let old, old != id { reportEnd(old, by: .replaced) }  // before the sender's counts go to the new session
        liveLink = id
        resends.clear()  // a new session asks only for what it was sent
        sender.attach(sealer: s.mediaSealer, address: s.address)
        framesFromGame = 0
        lastHostStats = self.now()
        lastHello = s.hello
        pendingRate = nil
        if let old, old != id {
            // Another device took the Mac from a library session: the old session is told by whom before it closes.
            if let was = links[old]?.session?.peer, was.key != s.peer.key {
                send(old, .bye(takenBy: shownName(of: s.peer.key)))
                end(old, afterSend: true, by: .replaced)
            } else {
                end(old, by: .replaced)
            }
        }  // replaced: not live any more, so the model never hears of it
        // A library session never reconfigures the game: it is configured when a session plays, before the game resumes
        // (as `play()` does), so its first pictures are at that session's size and rate -> .claude/host.md § service
        if model.playing, game?.connected == true { configureTap() }
        perform(actions)
        sendState()
        lastConfigNs = 0  // the new session's first `rate` goes to the game at once
        publishStatus()
    }

    private func refuse(_ id: Int, _ r: Refusal) {
        send(id, .refuse(r))
        end(id, afterSend: true, by: .controlError)
    }

    /// Forgets the connection; `clientLeft` and the session-end line (`by`) only when it was the live one.
    func end(_ id: Int, afterSend: Bool = false, by cause: SessionEndCause) {
        if liveLink == id { reportEnd(id, by: cause) }
        guard let link = links.removeValue(forKey: id) else { return }
        if pairing?.owner == id { pairing?.owner = nil }
        let connection = link.connection
        if afterSend {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        } else {
            connection.cancel()
        }
        guard liveLink == id else { return }
        liveLink = nil
        sender.detach()
        resends.clear()  // the session's frames go with it
        perform(model.clientLeft(at: self.now()))
        publishStatus()
    }

    /// Sealed once the connection has a session.
    func send(_ id: Int, _ m: ControlMessage) {
        guard links[id] != nil, let json = try? m.encoded() else { return }
        var payload = json
        if links[id]!.session != nil {
            guard let sealed = try? links[id]!.session!.controlSealer.seal(json) else { return }
            payload = sealed
        }
        links[id]!.connection.send(content: ControlFramer.frame(payload), completion: .contentProcessed { _ in })
    }

    private func newSessionID() -> UInt32 {
        var rng = SystemRandomNumberGenerator()
        let used = Set(links.values.compactMap { $0.session?.sessionID })
        while true {
            let id = UInt32.random(in: 1...UInt32.max, using: &rng)
            if !used.contains(id) { return id }
        }
    }

    // MARK: status

    func publishStatus() {
        guard lifecycle.failure == nil else { return }
        let s: HostStatus
        if let p = pairing {
            s = .pairing(code: p.code, until: p.startedAt.addingTimeInterval(PairingLimits.lifetime))
        } else if let id = liveLink, let peer = links[id]?.session?.peer {
            s = .live(device: shownName(of: peer.key), tag: peer.tag, game: game?.app.name)
        } else if let g = game, model.gamePaused {
            s = .paused(game: g.app.name)
        } else {
            s = .idle
        }
        guard s != lastStatus else { return }
        lastStatus = s
        statusOut.yield(s)
    }
}
#endif
