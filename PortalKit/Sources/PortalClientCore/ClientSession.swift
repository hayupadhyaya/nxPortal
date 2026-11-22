import CryptoKit
import Foundation
import Network
import PortalKit

public enum ClientError: Error, Equatable { case refused(Refusal), pairing(PairResult), closed, timeout }

/// Why a session ended -> .claude/client.md § session
public enum SessionEnd: Hashable, Sendable {
    /// `close()` (or an `open` the Host never proved).
    case local
    /// The Host said `bye`, the connection ended, or the Host sent bytes that do not open.
    case hostClosed
    /// Nothing opened for `silenceTimeout`.
    case silence
    /// No datagram from the Host opened in the first 2 s of the media: its media cannot reach this device.
    case mediaPathSilent
    /// The Host gave the Mac to another device (a sealed `bye` with `takenBy`, its shown name; nil when it named none).
    case takenOver(by: String?)
}

/// One `art` message from the Host -> .claude/client.md § session
public struct ArtChunk: Equatable, Sendable {
    public var titleID: String, hash: String, index: UInt16, count: UInt16, bytes: Data
    public init(titleID: String, hash: String, index: UInt16, count: UInt16, bytes: Data) {
        self.titleID = titleID; self.hash = hash; self.index = index; self.count = count; self.bytes = bytes
    }
}

/// The client half of the streaming protocol: connect, pair, open, play -> .claude/client.md § session
public actor ClientSession {
    struct Waiter {
        let id: Int
        let accepts: @Sendable (ControlMessage) -> Bool
        let continuation: CheckedContinuation<ControlMessage, Error>
        let timer: Task<Void, Never>
    }

    /// Kept from `hello` until `welcome` arrives; the keys are derived the moment it does.
    struct Handshake { let ephemeral: Curve25519.KeyAgreement.PrivateKey; let host: PairedPeer }

    public nonisolated let frames: AsyncStream<AssembledFrame>
    public nonisolated let audio: AsyncStream<AudioBlock>
    public nonisolated let states: AsyncStream<GameState>
    /// `true` after `stallAfterNs` without anything from the Host, `false` at the next datagram or control frame.
    public nonisolated let stalls: AsyncStream<Bool>
    /// Every sealed `art` message, whether or not anyone waits (the oldest `artBuffer` are kept while unread).
    public nonisolated let arts: AsyncStream<ArtChunk>
    /// Every sealed `options` reply, whichever of the four messages it answers (nobody `expect`s them; the oldest
    /// `optionBuffer` are kept while unread) -> .claude/client.md § session
    public nonisolated let optionReplies: AsyncStream<GameOptions>
    /// One event per sealed `options` reply the decoder refused (over `OptionLimits`): the session goes on, and the reply
    /// answered the oldest options message still unanswered (the Host answers them in order).
    public nonisolated let optionRefusals: AsyncStream<Void>
    static let artBuffer = 32, optionBuffer = 32
    let framesOut: AsyncStream<AssembledFrame>.Continuation
    let audioOut: AsyncStream<AudioBlock>.Continuation
    let statesOut: AsyncStream<GameState>.Continuation
    let stallsOut: AsyncStream<Bool>.Continuation
    let artsOut: AsyncStream<ArtChunk>.Continuation
    let optionsOut: AsyncStream<GameOptions>.Continuation
    let optionRefusalsOut: AsyncStream<Void>.Continuation

    let identity: Identity, name: String, kind: DeviceKind
    let maxWidth: UInt16, maxHeight: UInt16, maxFps: UInt8
    /// The stream bitrate wished for (bit/s): the ceiling the rate controller stays under; nil = the Host's default (fixed).
    let bitrate: UInt32?
    /// Test tools: media datagrams go here instead of the Host's address and `welcome.udpPort`.
    let mediaVia: (host: String, port: UInt16)?
    /// Test tools: told `welcome.udpPort` before the media link starts (a shaper learns the Host's port from it).
    let mediaPortKnown: (@Sendable (UInt16) -> Void)?
    /// Test tools: the local address the media link sends from (nil: the system picks).
    let mediaFrom: String?
    /// Nothing that opens for this long after `open()` ends the session.
    let silenceNs: UInt64
    /// How long a reply to one request may take (also the bound of the app's options calls).
    public static let replyTimeout: TimeInterval = 5
    /// Seconds without a datagram or control frame from the Host before the session ends -> .claude/client.md § session
    public static let defaultSilenceTimeout: TimeInterval = 10
    /// How long a reply is awaited (internal init parameter: tests shorten it).
    let replyTimeout: TimeInterval

    var control: NWLink?
    var mediaLink: NWLink?
    var framer = ControlFramer()
    var handshake: Handshake?
    var controlSealer: StreamSealer?
    var controlOpener: StreamOpener?
    var mediaSealer: DatagramSealer?
    var mediaOpener: DatagramOpener?
    var welcome: Welcome?
    /// Pending replies, oldest first; a message goes to the first that accepts it.
    var waiters: [Waiter] = []
    var nextWaiter = 0
    var closed = false
    /// Why the session ended; set before the streams finish.
    public private(set) var end: SessionEnd?
    var tasks: [Task<Void, Never>] = []

    // Media state -> ClientSession+Media.swift
    var assembler = FrameAssembler()
    var tracker = StatsTracker(startNs: uptimeNs())
    var awaitingKey = false
    var lastKeyRequestNs: UInt64 = 0
    /// A frame was given up and `repair` asked for: when first and last, how many sent; nil once a restart point is out
    /// -> `ClientSession+Media.swift`
    var repairWait: (firstNs: UInt64, lastNs: UInt64, sent: Int)?
    /// The assembler's `framesGivenUp` when last looked at: a frame given up during a repair wait is a lost restart point.
    var givenUpSeen = 0
    /// When the newest `ack` went out.
    var lastAckNs: UInt64 = 0
    var lastGoodFrame: UInt32 = 0
    var lastPingNs: UInt64 = 0
    var inputSeq: UInt32 = 0
    var latestInput: [UInt8: InputState] = [:]
    /// Times the newest input of each player went out.
    var inputSent: [UInt8: Int] = [:]
    /// Runs only while the assembler has something missing -> `ClientSession+Media.swift`.
    var repairTimer: Task<Void, Never>?
    /// When the repair timer next wakes; the running timer's generation (an older one stops at its next step).
    var repairDueNs: UInt64 = 0
    var repairGeneration = 0
    var datagramIndex = 0
    var datagramFilter: (@Sendable (Int) -> Bool)?
    /// Test seam: every datagram the session sends, before it is sealed.
    var sendObserver: (@Sendable (Datagram) -> Void)?
    /// Tests: video fragments it returns true for are dropped as if lost on the link (`dropVideo`).
    var videoDrop: (@Sendable (VideoFragment) -> Bool)?
    /// Last datagram or control frame that opened; 0 until `open()` completes.
    var lastHeardNs: UInt64 = 0
    /// When the newest Host datagram of any kind arrived (the assembler's tail rule: silence from everything is a stalled radio).
    var newestHostNs: UInt64 = 0
    /// A datagram from the Host has opened in this session (the media path works) -> `mediaPathNs`.
    var mediaOpened = false
    /// True between the stall and the next thing from the Host (`stalls` reports the changes).
    var stalled = false
    /// After a recovery: captures (Host clock) before this are stale until `staleUntilNs` -> `ClientSession+Media.swift`.
    var staleBeforeHostNs: Int64 = 0
    var staleUntilNs: UInt64 = 0
    /// The rate controller (nil: the rate stays at the wish) and what its samples are made of -> `ClientSession+Media.swift`.
    var rate: RateController?
    var lastRateSampleNs: UInt64 = 0, lastRateSentNs: UInt64 = 0
    /// Video fragments received and frames put out since the session began; the assembler counts at the last sample.
    var fragmentsIn = 0, sampledIn = 0, sampledAsked = 0, sampledGivenUp = 0, bytesIn = 0, sampledBytes = 0
    /// Repeats of the newest cut still to send (`cutRepeatNs` apart).
    var cutRepeatsLeft = 0
    var framesCompleted = 0, sampledCompleted = 0
    /// Video payload received, and what the encoder produced (frame sizes from their fragments), per 50 ms.
    var delivered = SlotRate(slots: 8), produced = SlotRate(slots: 20)
    /// The newest frame number seen in this stream (its size is counted once, at its first fragment).
    var newestFrameSeen: UInt32?
    /// When the media started (the rate log's time base) and the rate's changes, the newest 32 -> `SessionStats.rateChanges`.
    var mediaStartNs: UInt64 = 0
    var rateChanges: [RateChange] = []
    var rateChangeSeq = 0
    /// The first rate and the lowest, over the session (the log above rolls).
    var rateStartBps: UInt32 = 0, rateLowBps: UInt32 = 0
    /// The first video fragment of this stream (start or restart): before 300 ms of it the delivered rate is not known.
    var videoSinceNs: UInt64?

    /// A session dropped without `close()` still lets go: the links are cancelled, so the Host sees the client leave.
    deinit {
        control?.cancel()
        mediaLink?.cancel()
        for t in tasks { t.cancel() }
        repairTimer?.cancel()
        framesOut.finish()
        audioOut.finish()
        statesOut.finish()
        stallsOut.finish()
        artsOut.finish()
        optionsOut.finish()
        optionRefusalsOut.finish()
    }

    /// `silenceTimeout`: seconds without a datagram or control frame that opens before the session ends
    /// -> .claude/client.md § session. `bitrate` is a ceiling: with `adaptiveRate` (the default) the session steers the
    /// Host's rate below it (`RateController`); without, the rate stays at the wish.
    public init(identity: Identity, name: String, kind: DeviceKind, maxWidth: UInt16, maxHeight: UInt16,
                maxFps: UInt8, bitrate: UInt32? = nil, adaptiveRate: Bool = true,
                silenceTimeout: TimeInterval = ClientSession.defaultSilenceTimeout,
                mediaVia: (host: String, port: UInt16)? = nil, mediaPortKnown: (@Sendable (UInt16) -> Void)? = nil) {
        self.init(identity: identity, name: name, kind: kind, maxWidth: maxWidth, maxHeight: maxHeight, maxFps: maxFps,
                  bitrate: bitrate, adaptiveRate: adaptiveRate, silenceTimeout: silenceTimeout, replyTimeout: Self.replyTimeout,
                  mediaVia: mediaVia, mediaPortKnown: mediaPortKnown)
    }

    init(identity: Identity, name: String, kind: DeviceKind, maxWidth: UInt16, maxHeight: UInt16, maxFps: UInt8,
         bitrate: UInt32? = nil, adaptiveRate: Bool = true, silenceTimeout: TimeInterval = ClientSession.defaultSilenceTimeout,
         replyTimeout: TimeInterval,
         mediaVia: (host: String, port: UInt16)? = nil, mediaPortKnown: (@Sendable (UInt16) -> Void)? = nil,
         mediaFrom: String? = nil) {
        self.bitrate = bitrate
        self.mediaFrom = mediaFrom
        if adaptiveRate, let bitrate { rate = RateController(ceilingBps: bitrate) }
        self.mediaVia = mediaVia
        self.mediaPortKnown = mediaPortKnown
        tracker = StatsTracker(startNs: uptimeNs(), maxFps: Int(maxFps))
        self.replyTimeout = replyTimeout
        self.identity = identity; self.name = DeviceName.clean(name) ?? DeviceName.fallback; self.kind = kind
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxFps = maxFps
        silenceNs = UInt64(silenceTimeout * 1e9)
        (frames, framesOut) = AsyncStream.makeStream(of: AssembledFrame.self, bufferingPolicy: .unbounded)
        (audio, audioOut) = AsyncStream.makeStream(of: AudioBlock.self, bufferingPolicy: .unbounded)
        (states, statesOut) = AsyncStream.makeStream(of: GameState.self, bufferingPolicy: .unbounded)
        (stalls, stallsOut) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .unbounded)
        (arts, artsOut) = AsyncStream.makeStream(of: ArtChunk.self, bufferingPolicy: .bufferingOldest(Self.artBuffer))
        (optionReplies, optionsOut) = AsyncStream.makeStream(of: GameOptions.self, bufferingPolicy: .bufferingOldest(Self.optionBuffer))
        (optionRefusals, optionRefusalsOut) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingOldest(Self.optionBuffer))
    }

    // MARK: calls

    public func connect(to endpoint: NWEndpoint) async throws {
        guard control == nil, !closed else { throw ClientError.closed }
        let link = NWLink(endpoint: endpoint, udp: false)
        control = link
        try await link.start(timeout: 10)
        guard !closed else { link.cancel(); throw ClientError.closed }
        let inbound = link.inbound
        tasks.append(Task { [weak self] in
            for await bytes in inbound { await self?.controlBytes(bytes) }
            await self?.controlEnded()
        })
    }

    public func pair(code: String) async throws -> PairedPeer {
        var client = PairingClient(identity: identity, name: name)
        sendClear(.pairStart(client.start()))
        let reply = try await expect { if case .pairChallenge = $0 { true } else if case .pairResult = $0 { true } else { false } }
        if case let .pairResult(result) = reply { throw ClientError.pairing(result) }
        guard case let .pairChallenge(challenge) = reply else { throw ClientError.closed }
        sendClear(.pairProof(try client.proof(for: challenge, code: code)))
        guard case let .pairResult(result) = try await expect({ if case .pairResult = $0 { true } else { false } }) else {
            throw ClientError.closed
        }
        guard case .ok = result else { throw ClientError.pairing(result) }
        return try client.finish(result)
    }

    /// hello -> welcome, then the sealed `ready`; returns once the first sealed frame from the Host has opened, then the first ping.
    /// `resume: false` opens a library session (the Host resumes nothing on admission); nil = a resuming one -> .claude/client.md § model
    public func open(host: PairedPeer, resume: Bool? = nil) async throws {
        guard let control, !closed else { throw ClientError.closed }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        handshake = Handshake(ephemeral: ephemeral, host: host)
        // The start rate is the controller's, the same value as the first `rate` -> .claude/client.md § rate
        sendClear(.hello(Hello(version: ProtocolVersion.network, clientKey: identity.publicKey,
                               ephemeral: ephemeral.publicKey.rawRepresentation, kind: kind,
                               maxWidth: maxWidth, maxHeight: maxHeight, maxFps: maxFps, bitrate: bitrate, resume: resume,
                               startBps: rate?.rateBps, name: name)))
        let reply = try await expect { if case .welcome = $0 { true } else if case .refuse = $0 { true } else { false } }
        if case let .refuse(r) = reply { throw ClientError.refused(r) }
        guard let welcome, let remote = control.remoteHost else { throw ClientError.closed }
        mediaPortKnown?(welcome.udpPort)
        let mediaHost = mediaVia.map { NWEndpoint.Host($0.host) } ?? remote
        let mediaPort = mediaVia?.port ?? welcome.udpPort
        let udp = NWLink(endpoint: .hostPort(host: mediaHost, port: NWEndpoint.Port(rawValue: mediaPort) ?? .any), udp: true,
                         from: mediaFrom.map { .hostPort(host: NWEndpoint.Host($0), port: .any) })
        mediaLink = udp
        try await udp.start(timeout: replyTimeout)
        guard !closed else { udp.cancel(); throw ClientError.closed }
        let inbound = udp.inbound
        tasks.append(Task { [weak self] in for await d in inbound { await self?.datagram(d) } })
        sendSealed(.ready)
        // The Host proves it holds its key by the first frame that opens (its `gameState` on admission).
        do { _ = try await expect({ _ in true }) } catch ClientError.timeout {
            shutdown(final: nil, reason: .local)
            throw ClientError.timeout
        }
        startedMedia()
    }

    public func list() async throws -> [GameEntry] {
        sendSealed(.listRequest)
        guard case let .list(entries) = try await expect({ if case .list = $0 { true } else { false } }) else {
            throw ClientError.closed
        }
        return entries
    }

    /// The outcome arrives on `states`.
    public func launch(titleID: String) async throws { try sendOpen(.launch(titleID: titleID)) }
    public func resume() async throws { try sendOpen(.resume) }
    /// The answer arrives on `arts`.
    public func requestArt(titleID: String, hash: String) async throws { try sendOpen(.artRequest(titleID: titleID, hash: hash)) }
    public func quitGame() async throws { try sendOpen(.quitGame) }
    /// The answers to these three (and to the request) arrive on `optionReplies`; `value` nil removes the choice.
    public func optionsRequest(titleID: String) async throws { try sendOpen(.optionsRequest(titleID: titleID)) }
    public func setOption(titleID: String, env: String, value: String?) async throws {
        try sendOpen(.setOption(titleID: titleID, env: env, value: value))
    }
    public func resetOptions(titleID: String) async throws { try sendOpen(.resetOptions(titleID: titleID)) }

    /// Tells the Host the ceiling and the panel level (admitted session only). A ceiling also becomes the rate controller's:
    /// a lowered one cuts the rate at once and the new rate goes out as a cut does; a raised one waits for the normal climb.
    public func sendLive(_ s: LiveSettings) async throws {
        try sendOpen(.liveSettings(s))
        guard let ceiling = s.ceilingBps, ceiling > 0, let before = rate?.rateBps else { return }
        guard let lowered = rate?.setCeiling(ceiling) else { return }
        let now = uptimeNs()
        logRate(now, from: before, to: lowered, why: rate?.reason ?? .start, delivered: 0, produced: 0, floorNs: nil)
        sendRate(now)
        cutRepeatsLeft = Self.cutRepeats
    }

    /// Sealed `bye`, both connections cancelled, the streams finished. Idempotent.
    public func close() async {
        guard !closed else { return }
        let bye = sealed(.bye())
        shutdown(final: bye, reason: .local)
    }

    public func stats() -> SessionStats {
        tracker.repairCounts(assembler.counts)
        var s = tracker.snapshot(nowNs: uptimeNs())
        s.rateBps = rate?.rateBps ?? 0
        s.rateCeilingBps = rate?.ceilingBps ?? bitrate ?? 0
        s.rateCuts = rate?.cuts ?? 0
        s.rateChanges = rateChanges
        s.rateStartBps = rateStartBps; s.rateLowBps = rateLowBps
        return s
    }

    /// The recorder's second: the largest video-datagram interval and round trip since the last call (the panel's `stats()` does not reset them).
    public func takeSecondMaxima() -> SecondMaxima { tracker.takeMaxima() }

    /// The rate the session asks of the Host now (bit/s); nil when the rate is fixed.
    public var currentRate: UInt32? { rate?.rateBps }

    func setSendObserver(_ observe: (@Sendable (Datagram) -> Void)?) { sendObserver = observe }
    func setIncomingDatagramFilter(_ keep: (@Sendable (Int) -> Bool)?) { datagramFilter = keep }

    /// Tests: every video fragment `drop` returns true for is dropped on arrival, as if the link had lost it (a test link
    /// cannot read a sealed fragment's frame number or mark).
    public func dropVideo(_ drop: (@Sendable (VideoFragment) -> Bool)?) { videoDrop = drop }

    // MARK: control plumbing

    private func sendOpen(_ m: ControlMessage) throws {
        guard !closed, controlSealer != nil else { throw ClientError.closed }
        sendSealed(m)
    }

    private func sendClear(_ m: ControlMessage) {
        guard let json = try? m.encoded() else { return }
        control?.send(ControlFramer.frame(json))
    }

    private func sealed(_ m: ControlMessage) -> Data? {
        guard controlSealer != nil, let json = try? m.encoded(), let box = try? controlSealer!.seal(json) else { return nil }
        return ControlFramer.frame(box)
    }

    func sendSealed(_ m: ControlMessage) {
        if let data = sealed(m) { control?.send(data) }
    }

    private func controlBytes(_ bytes: Data) {
        guard !closed else { return }
        guard let payloads = try? framer.push(bytes) else { return shutdown(final: nil, reason: .hostClosed) }
        for p in payloads {
            guard !closed else { return }
            var json = p
            let sealed = controlOpener != nil
            if sealed {
                guard let opened = try? controlOpener!.open(p) else { return shutdown(final: nil, reason: .hostClosed) }
                json = opened
                heard(uptimeNs())
            }
            let m: ControlMessage
            do { m = try ControlMessage(decoding: json) } catch WireError.refused {
                if sealed { optionRefusalsOut.yield() }  // over its limits (`OptionLimits`): not shown, the session goes on, the model is told
                continue
            } catch { return shutdown(final: nil, reason: .hostClosed) }
            route(m, sealed: sealed)
        }
    }

    /// `gameState`, `art`, `options` and `bye` count only when sealed: in the clear before `welcome` anyone can send them.
    private func route(_ m: ControlMessage, sealed: Bool) {
        switch m {
        case let .welcome(w):
            guard !sealed, deriveKeys(w) else { return shutdown(final: nil, reason: .hostClosed) }
            deliver(m)
        case let .gameState(s):
            guard sealed else { return }
            // A new game numbers its frames from 0 again -> .claude/client.md § session
            if s.run == .idle || s.run == .starting { restartVideo() }
            statesOut.yield(s)
            deliver(m)
        case let .art(titleID, hash, index, count, bytes):
            if sealed { artsOut.yield(ArtChunk(titleID: titleID, hash: hash, index: index, count: count, bytes: bytes)) }
        case let .options(o):
            if sealed { optionsOut.yield(o) }
        case let .bye(takenBy):
            // cleaned again: the wire is not trusted
            if sealed { shutdown(final: nil, reason: takenBy.map { .takenOver(by: DeviceName.clean($0)) } ?? .hostClosed) }
        default: deliver(m)
        }
    }

    private func deriveKeys(_ w: Welcome) -> Bool {
        guard let h = handshake,
              let keys = try? SessionKeys.derive(role: .client, identity: identity, ephemeral: h.ephemeral,
                                                 peerKey: h.host.key, peerEphemeral: w.ephemeral) else { return false }
        handshake = nil
        welcome = w
        controlSealer = StreamSealer(key: keys.clientToHostControl)
        controlOpener = StreamOpener(key: keys.hostToClientControl)
        mediaSealer = DatagramSealer(key: keys.clientToHostMedia, sessionID: w.sessionID)
        mediaOpener = DatagramOpener(key: keys.hostToClientMedia, sessionID: w.sessionID)
        return true
    }

    private func controlEnded() { shutdown(final: nil, reason: .hostClosed) }

    /// Waits for the next control message `accepts`; 5 s -> `.timeout`, the connection ending -> `.closed`.
    private func expect(_ accepts: @escaping @Sendable (ControlMessage) -> Bool) async throws -> ControlMessage {
        guard !closed else { throw ClientError.closed }
        let id = nextWaiter
        nextWaiter += 1
        let wait = UInt64(replyTimeout * 1e9)
        return try await withCheckedThrowingContinuation { c in
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: wait)
                if !Task.isCancelled { await self?.expire(id) }
            }
            waiters.append(Waiter(id: id, accepts: accepts, continuation: c, timer: timer))
        }
    }

    private func deliver(_ m: ControlMessage) {
        guard let i = waiters.firstIndex(where: { $0.accepts(m) }) else { return }
        let w = waiters.remove(at: i)
        w.timer.cancel()
        w.continuation.resume(returning: m)
    }

    private func expire(_ id: Int) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.continuation.resume(throwing: ClientError.timeout)
    }

    func shutdown(final: Data?, reason: SessionEnd) {
        guard !closed else { return }
        closed = true
        end = reason
        let pending = waiters
        waiters = []
        for w in pending { w.timer.cancel(); w.continuation.resume(throwing: ClientError.closed) }
        control?.close(sending: final)
        control?.finish()
        mediaLink?.cancel()
        for t in tasks { t.cancel() }
        tasks = []
        repairTimer?.cancel()
        repairTimer = nil
        framesOut.finish()
        audioOut.finish()
        statesOut.finish()
        stallsOut.finish()
        artsOut.finish()
        optionsOut.finish()
        optionRefusalsOut.finish()
    }
}
