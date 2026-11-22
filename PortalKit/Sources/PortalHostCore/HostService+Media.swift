#if os(macOS)
import Foundation
import os
import PortalKit

/// Media relay, tap events, the 100 ms tick, session actions and games -> .claude/host.md § service
/// The newest `prepare` of the running game.
public struct GamePrepare: Equatable, Sendable {
    public var phase: UInt8, done: UInt32, total: UInt32
}

extension HostService {
    static let keyframeInterval: TimeInterval = 0.1
    /// A client repeats `repair` every 100 ms; the game serves one at a time itself, so the Host only stops a flood.
    static let refreshInterval: TimeInterval = 0.02
    /// At most one `config` to the game per 250 ms for a client's `rate`.
    static let rateIntervalNs: UInt64 = 250_000_000
    /// A progress-only `gameState` goes out at most this often.
    static let preparingIntervalNs: UInt64 = 500_000_000
    static let quitGrace: TimeInterval = 5
    static let maxUnadmitted = 16
    /// A library scan is reused this long (1 s of uptime = 1e9 ns).
    static let scanLifetimeNs: UInt64 = 2_000_000_000

    /// Sender lateness since the service started: slices, 95th percentile and worst, in microseconds (tests, `portal-hostd`).
    public var senderLateness: (slices: Int, p95Us: Int, maxUs: Int) {
        let l = sender.lateness
        return (l.slices, l.p95Us, l.maxUs)
    }

    /// What the resend store refused since the service started (tests; no log line per datagram).
    var resendRefused: ResendStore.Refused { resends.refused }

    /// The rate kept for the welcomed session of the device shown as `name` (tests).
    func keptRate(of name: String) -> UInt32? {
        let shown = PairedDevice.shownNames(store.peers)
        return links.values.first { $0.session.map { shown[$0.peer.key] == name } ?? false }?.session?.rateBps
    }

    // MARK: media in

    /// Opened by the session its header names; one that does not open changes nothing.
    /// A welcomed session not yet admitted learns its address only.
    func handle(_ d: InboundDatagram) {
        guard !stopped else { return }
        let others = links.keys.filter { $0 != liveLink && links[$0]?.session != nil }
        for id in (liveLink.map { [$0] } ?? []) + others {
            let opened: (type: UInt8, body: Data)
            do { opened = try links[id]!.session!.mediaOpener.open(d.data) } catch SealError.wrongSession { continue } catch { return }
            links[id]!.session!.address = d.from
            links[id]!.session!.counters.datagramOpened(at: self.now())
            guard id == liveLink else { return }
            sender.setAddress(d.from)
            let now = self.now()
            guard let datagram = try? Datagram(type: opened.type, body: opened.body) else {
                return model.packetReceived(at: now)
            }
            return media(id, datagram, at: now)
        }
    }

    private func media(_ id: Int, _ d: Datagram, at now: Date) {
        if pendingRate != nil { applyPendingRate() }  // due once 250 ms have passed (any datagram: input comes every 8 ms)
        switch d {
        case let .input(s):
            // Player 0 only in phase 1; a seq not newer than the last accepted is stale (UDP reorders).
            let last = links[id]!.session!.lastInputSeq
            guard s.player == 0, last.map({ s.seq > $0 }) ?? true else {
                return model.packetReceived(at: now)
            }
            links[id]!.session!.lastInputSeq = s.seq
            guard model.playing else { return model.packetReceived(at: now) }  // a library session moves no pad
            model.inputReceived(at: now)
            tap.send(.pad(player: 0, buttons: s.buttons, lx: s.lx, ly: s.ly, rx: s.rx, ry: s.ry))
            if let m = s.motion { tap.send(.motion(player: 0, frame: m.frame, acc: m.acc, rot: m.rot)) }
        case .keyRequest:
            model.packetReceived(at: now)
            guard model.playing else { return }  // a library session asks the game for nothing
            guard now.timeIntervalSince(lastKeyframe) >= Self.keyframeInterval else { return }
            lastKeyframe = now
            applyPendingRate(force: true)  // the key frame is sized by the newest rate
            tap.send(.keyframe)
        case .repair:
            // The game decides between a repair frame and a key frame -> .claude/host.md § ltr
            model.packetReceived(at: now)
            guard model.playing else { return }
            guard now.timeIntervalSince(lastRefresh) >= Self.refreshInterval else { return }
            lastRefresh = now
            applyPendingRate(force: true)  // as for a key frame: the rate first
            tap.send(.refresh)
        case let .ack(frame):
            model.packetReceived(at: now)
            if let token = acks.ack(frame, nowNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) { tap.send(.ltrAck([token])) }
        case let .rate(bps):
            model.packetReceived(at: now)
            rateWished(id, bps)
        case let .ping(clientNs):
            model.packetReceived(at: now)
            sendMedia(.pong(clientNs: clientNs, hostNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), .urgent)
        case let .nack(frame, indices):
            // Sealed afresh by `sendMedia`; refusals are counted in the store, never logged per datagram.
            model.packetReceived(at: now)
            for f in resends.resend(frame: frame, indices: indices, nowNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
                sendMedia(.video(f), .resend)
            }
        default:
            model.packetReceived(at: now)
        }
    }

    /// The client's newest rate, clamped; the game gets it now, or once 250 ms have passed since the last config
    /// (one pending slot: the newest replaces an older one, so a cut never waits behind an increase).
    private func rateWished(_ id: Int, _ bps: UInt32) {
        guard let s = links[id]?.session else { return }
        let r = min(max(bps, HostDefaults.minBitrate), ceiling(of: s))
        links[id]!.session!.rateBps = r
        // the game's first config carries it; a session that does not play keeps it for when it plays
        guard game?.connected == true, model.playing else { return }
        pendingRate = r == videoBitrate ? nil : r
        applyPendingRate()
    }

    /// The most the session may be given: its live ceiling, else its hello's wish, else the default; never over `maxBitrate`
    /// or under 1 Mbit/s.
    func ceiling(of s: Session) -> UInt32 {
        max(min(s.ceilingBps ?? s.hello.bitrate ?? config.defaultBitrate, config.maxBitrate), HostDefaults.minBitrate)
    }

    /// `liveSettings` from an admitted device: a ceiling (0 ignored) is clamped to `[1 Mbit/s, maxBitrate]` and replaces the
    /// hello's wish; a rate above it is cut to it for the next config; the panel level is kept for the Host's sampler.
    /// A running game's process is never touched -> .claude/host.md § service
    func applyLive(_ id: Int, _ live: LiveSettings) {
        guard links[id]?.session != nil else { return }
        if let wanted = live.ceilingBps, wanted > 0 {
            let c = min(max(wanted, HostDefaults.minBitrate), config.maxBitrate)
            links[id]!.session!.ceilingBps = c
            if let r = links[id]!.session!.rateBps, r > c { links[id]!.session!.rateBps = c }
            // a raise still waiting for the 250 ms interval never passes the new ceiling
            if id == liveLink, let queued = pendingRate, queued > c { pendingRate = c == videoBitrate ? nil : c }
            // the Host is the authority: a lowered ceiling reaches the encoder now, not with the client's next `rate`
            // (the client's controller is already under the same ceiling, so its own cut asks for the same value or less)
            if id == liveLink, game?.connected == true, model.playing, videoBitrate > c {
                pendingRate = c
                applyPendingRate(force: true)
            }
        }
        if let level = live.panel { links[id]!.session!.panel = level }
    }

    func applyPendingRate(force: Bool = false) {
        guard let r = pendingRate, game?.connected == true else { return }
        guard force || clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- lastConfigNs >= Self.rateIntervalNs else { return }
        sendConfig(bitrate: r)
    }

    // MARK: media out

    /// To the live session through the sender (sealed there, at send time); dropped before its address is known.
    private func sendMedia(_ d: Datagram, _ priority: MediaSender.Priority) {
        guard let id = liveLink, links[id]?.session?.address != nil else { return }
        sender.enqueue(d, priority: priority)
    }

    /// The resend store and the sender's queued video are forgotten together.
    func clearResends() {
        resends.clear()
        sender.discardQueued()
        acks.clear()  // tokens of frames the device can no longer acknowledge
    }

    /// Medians of the frame sizes the game sent (bytes; 0 = none) and how many of each kind (`portal-hostd`'s exit line).
    public var frameSizeMedians: (ordinary: Int, repair: Int, key: Int, repairs: Int, keys: Int) {
        (sizes.median(.none), sizes.median(.repair), sizes.median(.key), sizes.counts[2], sizes.counts[1])
    }

    /// The running game's newest `prepare`, nil before the first or without a game.
    public var gamePrepare: GamePrepare? { game?.prepare }

    func note(_ line: String) {
        Self.sessionLog.notice("\(line, privacy: .public)")
        notesOut.yield(line)
    }

    func handle(_ e: TapEvent) {
        guard !stopped else { return }
        switch e {
        case .hello:
            guard game != nil, game?.connected == false else { return tap.send(.quit) }  // not a game we launched
            game?.connected = true
            clearResends()  // a new game numbers its frames from 0
            let actions = model.gameStarted(at: self.now())
            configureTap()
            perform(actions)
            sendState()
            publishStatus()
        case let .video(frame, captureNs, width, height, mark, token, data):
            // A picture ends the preparation even when no device is looking: an owed pause goes out now.
            game?.tracker.picture(now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            releaseDeferredPause()
            publishPreparing()
            noteRender(width: width, height: height)
            guard !model.gamePaused, model.playing, liveLink.flatMap({ links[$0]?.session?.address }) != nil else { return }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            framesFromGame &+= 1
            if loadRunner != nil { loadFrames.push(captureNs: captureNs) }
            noteFrameRate(captureNs: captureNs, nowNs: now)
            sizes.add(data.count, mark: mark)
            acks.frame(frame, token: token, width: width, height: height, nowNs: now)
            // The game's mark goes into every fragment: the client restarts only at a key or repair frame.
            let fragments = FrameSplitter.split(frame: frame, key: mark == .key, repair: mark == .repair, captureNs: captureNs,
                                                width: width, height: height, data: data)
            for f in fragments { resends.keep(f, nowNs: now) }
            // A frame the sender drops unsent is forgotten here too: a `nack` for it finds nothing.
            for dropped in sender.enqueueFrame(fragments) { resends.discard(frame: dropped) }
        case let .audio(captureNs, pcm):
            guard !model.gamePaused, model.playing, let id = liveLink, links[id]?.session?.address != nil else { return }
            let seq = links[id]!.session!.audioSeq
            links[id]!.session!.audioSeq &+= 1
            sendMedia(.audio(seq: seq, captureNs: captureNs, pcm: pcm), .urgent)
        case let .prepare(phase, done, total):
            guard game?.connected == true else { return }
            preparing(GamePrepare(phase: phase, done: done, total: total))
            game?.tracker.progress(Preparing(phase: phase, done: done, total: total), now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            publishPreparing()
        case let .skipped(type):
            skippedTap[type, default: 0] += 1
            if skippedTap[type] == 1 { note(String(format: "tap: a message of unknown type 0x%02x skipped (counted from now)", type)) }
        case let .refused(text):
            if game != nil { abandonGame(reason: text) }
        case .closed:
            // The exit arrives from `waitForExit()`; a process that outlives its connection is ended like a quit.
            if game?.connected == true, game?.quitAt == nil { game?.quitAt = self.now() }
        }
    }

    /// Kept per running game; one line when a phase starts and one when it ends (`done == total`), none per message.
    private func preparing(_ p: GamePrepare) {
        let old = game?.prepare
        game?.prepare = p
        let now = self.now()
        if old?.phase != p.phase {
            game?.phaseStartedAt = now
            note("game prepare: phase \(p.phase) started (\(p.done)/\(p.total))")
        }
        if p.done == p.total, old.map({ $0.phase != p.phase || $0.done != $0.total }) ?? true {
            let s = now.timeIntervalSince(game?.phaseStartedAt ?? now)
            note(String(format: "game prepare: phase %d done (%u/%u) in %.1f s", p.phase, p.done, p.total, s))
        }
    }

    // MARK: tick and actions

    func tick() {
        guard !stopped else { return }
        let now = self.now()
        let actions = model.tick(at: now)
        if let id = liveLink, model.state == .detached {
            reportEnd(id, by: .clientSilent)
            liveLink = nil  // the model detached it (silence): close without a second clientLeft
            sender.detach()
            end(id, by: .clientSilent)
        }
        perform(actions)
        // Unadmitted links expire; the one running the active pairing lives until the pairing ends.
        for (id, link) in links where !link.admitted && pairing?.owner != id
            && now.timeIntervalSince(link.openedAt) >= config.unadmittedTimeout {
            end(id, by: .controlError)  // never live: no line
        }
        if let g = game {
            if !g.connected, now.timeIntervalSince(g.launchedAt) >= config.startTimeout {
                abandonGame(reason: "did not start")
            } else if let q = g.quitAt, !g.terminating, let h = g.handle, now.timeIntervalSince(q) >= Self.quitGrace {
                game?.terminating = true
                Task { await h.terminate() }
            }
        }
        if let p = pairing, Date().timeIntervalSince(p.startedAt) > PairingLimits.lifetime { pairing = nil }  // wall time: pairing window
        applyPendingRate()
        releaseDeferredPause()
        publishPreparing()
        sendHostStats(at: now)
        serviceLoad(at: now)
        publishStatus()
    }

    // MARK: load -> .claude/host.md § load

    /// First reading this long after the sampler is made (its own baseline); then one a second.
    static let loadFirstAfter: TimeInterval = 0.5
    static let loadEvery: TimeInterval = 1

    /// Once a second the game's frame rate from the capture times of the frames a playing device gets; a gap of over 2 s (a
    /// pause, a preparation) starts the measure afresh and the old one is dropped.
    func noteFrameRate(captureNs: UInt64, nowNs: UInt64) {
        if nowNs &- fpsLastFrameNs > 2_000_000_000 { fpsClock.restart(); measuredFps = nil; fpsTakenNs = nowNs }
        fpsLastFrameNs = nowNs
        fpsClock.push(captureNs: captureNs)
        guard nowNs &- fpsTakenNs >= 1_000_000_000 else { return }
        fpsTakenNs = nowNs
        if let f = fpsClock.take() { measuredFps = Int(f.fps.rounded()); fpsMeasuredNs = nowNs }
    }

    /// Only a playing live session whose device shows "full" is sampled; anything else stops it and forgets it.
    func serviceLoad(at now: Date) {
        guard let id = liveLink, let s = links[id]?.session, s.panel == .full, s.address != nil, model.playing else {
            stopLoad()
            return
        }
        if model.gamePaused { loadFrames.restart() }  // frames stop while paused: the first one after is not a stall
        let pid = game?.handle?.pid
        if loadRunner == nil {
            let runner = LoadRunner(config.loadSampler())
            loadRunner = runner
            loadFrames = FrameClock()
            lastLoadAt = now.addingTimeInterval(Self.loadFirstAfter - Self.loadEvery)
            loadInFlight = true  // the baseline read
            let generation = loadGeneration
            Task { [weak self] in
                _ = await runner.sample(pid: pid, now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                await self?.loadBaselineDone(generation)
            }
            return
        }
        guard !loadInFlight, now.timeIntervalSince(lastLoadAt) >= Self.loadEvery, let runner = loadRunner else { return }
        lastLoadAt = now
        loadInFlight = true
        let generation = loadGeneration
        Task { [weak self] in
            let reading = await runner.sample(pid: pid, now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            await self?.loadSampled(reading, generation: generation)
        }
    }

    private func loadBaselineDone(_ generation: Int) {
        if generation == loadGeneration { loadInFlight = false }
    }

    func stopLoad() {
        guard loadRunner != nil || loadInFlight else { return }
        loadRunner = nil
        loadInFlight = false
        loadGeneration &+= 1
        loadFrames = FrameClock()
        lastLoadAt = .distantPast
    }

    /// Sent on the lazy slot: behind every video and resend datagram, newest replaces, never retransmitted.
    private func loadSampled(_ r: MacLoadReading, generation: Int) {
        guard generation == loadGeneration, let id = liveLink, links[id]?.session?.panel == .full else { return }
        loadInFlight = false
        var h = HostLoad(gpuPresent: r.gpu != nil, gameAlive: r.gameAlive, thermal: r.thermal, pressure: r.pressure,
                         cpuTotal: r.cpuTotal, cpuPerf: r.cpuPerf, cpuEff: r.cpuEff, gpu: r.gpu ?? 0,
                         memUsedMiB: r.memUsedMiB, memTotalMiB: r.memTotalMiB, gameCpuCentiCores: r.gameCpuCentiCores,
                         gameMemMiB: r.gameMemMiB)
        if let f = loadFrames.take() {
            func deci(_ x: Double) -> UInt16 { UInt16(clamping: Int((x * 10).rounded())) }
            h.gameFpsDeci = deci(f.fps); h.frameMeanDeciMs = deci(f.meanMs); h.frameP95DeciMs = deci(f.p95Ms); h.frameMaxDeciMs = deci(f.maxMs)
        }
        sendMedia(.load(h), .lazy)
    }

    /// Once a second to the live session: the Host's own counts (an urgent datagram, never paced).
    private func sendHostStats(at now: Date) {
        guard liveLink != nil, now.timeIntervalSince(lastHostStats) >= 1 else { return }
        lastHostStats = now
        let c = sender.counts
        sendMedia(.hostStats(HostStats(framesFromGame: framesFromGame, framesSent: UInt32(truncatingIfNeeded: c.framesSent),
                                       framesDropped: UInt32(truncatingIfNeeded: c.framesDropped),
                                       resent: UInt32(truncatingIfNeeded: c.resent), rateBps: videoBitrate,
                                       sendLateMaxUs: UInt32(truncatingIfNeeded: sender.takeLateMaxUs()))), .urgent)
    }

    func perform(_ actions: [HostSessionModel.Action]) {
        for a in actions {
            switch a {
            case .neutralPads:
                tap.send(.pad(player: 0, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0))
                tap.send(.motionClear(player: 0))
            case .pauseGame:
                // A session that ends while the game prepares does not pause it: the pause is owed until the preparation ends.
                if game?.tracker.state(now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) != TrackerState.none, game != nil {
                    game?.pauseDeferred = true
                } else {
                    tap.send(.pause(true))
                    game?.tracker.pausedChanged(true, now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                }
                clearResends()
                sendState()
            case .resumeGame:
                if game?.pauseDeferred == true {
                    game?.pauseDeferred = false  // the game was never paused
                } else {
                    tap.send(.pause(false))
                    game?.tracker.pausedChanged(false, now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                }
                sendState()
            case .requestKeyframe:
                tap.send(.keyframe)
            case let .holdAwake(on):
                awake = on
                config.power.set(on)
            }
        }
    }

    // MARK: games

    private var runState: GameRunState {
        guard let g = game else { return .idle }
        if !g.connected { return .starting }
        return model.gamePaused && !g.pauseDeferred ? .paused : .running
    }

    /// What the device is told: nothing for a paused game or one showing pictures; `.waiting` while preparing with no
    /// fresh progress.
    var reportedPreparing: Preparing? {
        guard let g = game, case let .preparing(p) = g.tracker.state(now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) else { return nil }
        return p ?? .waiting
    }

    /// The owed pause, once the game shows a picture (the tracker is no longer preparing). A session that plays has cleared
    /// it already (`resumeGame`); a library session does not stop it.
    func releaseDeferredPause() {
        guard game?.pauseDeferred == true,
              game?.tracker.state(now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) == TrackerState.none else { return }
        game?.pauseDeferred = false
        tap.send(.pause(true))
        game?.tracker.pausedChanged(true, now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        clearResends()
        sendState()
    }

    /// A change of `preparing` goes to the live device: entering or leaving at once, a progress change at most twice a second.
    func publishPreparing() {
        guard liveLink != nil, game != nil else { return }
        let current = reportedPreparing
        guard current != sentPreparing else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if (current == nil) == (sentPreparing == nil), now &- lastPreparingSendNs < Self.preparingIntervalNs { return }
        lastPreparingSendNs = now
        sendState()
    }

    /// To the live connection: the given state, or the current one.
    func sendState(titleID: String? = nil, run: GameRunState? = nil, reason: String? = nil) {
        guard let id = liveLink else { return }
        let preparing = run == nil ? reportedPreparing : nil
        sentPreparing = preparing
        let shown = titleID ?? game?.app.titleID
        send(id, .gameState(GameState(titleID: shown, run: run ?? runState, reason: reason, preparing: preparing,
                                      render: shown == game?.app.titleID ? game?.render : nil)))
    }

    /// The hello that sizes the game: the live session's while it plays, else the player's the game was last configured
    /// with (a library session's limit never judges a picture), else the last hello.
    private var sizingHello: Hello? {
        if model.playing, let h = liveLink.flatMap({ links[$0]?.session?.hello }) { return h }
        return playerHello ?? lastHello
    }

    /// The size the tap was asked for, as `sendConfig` puts it: `sizingHello`'s, even and at least 320 x 180.
    private var sizeCap: (width: UInt16, height: UInt16) {
        let h = sizingHello
        return (UInt16(truncatingIfNeeded: max(h?.maxWidth ?? 1920, HostDefaults.minWidth) & ~1),
                UInt16(truncatingIfNeeded: max(h?.maxHeight ?? 1080, HostDefaults.minHeight) & ~1))
    }

    /// The game's picture size, told to the device when it changes: the game's own (exact) only when the fitted picture is under
    /// the cap on both sides; a game exactly the cap's size cannot be told from a scaled one (`RenderSize.fitted`).
    private func noteRender(width: UInt16, height: UInt16) {
        let cap = sizeCap
        let r = RenderSize.fitted(width: width, height: height, capWidth: cap.width, capHeight: cap.height)
        guard game?.render != r else { return }
        game?.render = r
        sendState()
    }

    /// From the playing session's `Hello` (else the last player's, `sizingHello`): its size (at least 320 x 180, even), its rate capped at 60, and
    /// the session's newest `rate`, else its bitrate wish (else the default) capped at `maxBitrate`, never under 1 Mbit/s.
    func configureTap() {
        let live = model.playing ? liveLink.flatMap { links[$0]?.session } : nil  // a library session never sizes the game
        if live != nil { playerHello = live?.hello }
        let wish = live.map(ceiling(of:)) ?? max(min(sizingHello?.bitrate ?? config.defaultBitrate, config.maxBitrate), HostDefaults.minBitrate)
        sendConfig(bitrate: live?.rateBps.map { min($0, wish) } ?? wish)
        tap.send(.players(mask: 1))
    }

    /// A `config` with the hello's size and frame rate and `bitrate`; the resend budget and the sender's pacing follow
    /// it (the tap changes the encoder's rate without a new session or key frame).
    private func sendConfig(bitrate: UInt32) {
        let h = sizingHello
        let width = max(h?.maxWidth ?? 1920, HostDefaults.minWidth) & ~1
        let height = max(h?.maxHeight ?? 1080, HostDefaults.minHeight) & ~1
        tap.send(.config(maxWidth: width, maxHeight: height, maxFps: min(h?.maxFps ?? 60, 60), bitrate: bitrate))
        resends.setBitrate(bitrate)  // the resend budget follows the video
        videoBitrate = bitrate
        sender.setStream(bitsPerSecond: bitrate)  // the pacing window follows it too
        pendingRate = nil
        lastConfigNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// The library's games and `extraGames`. The scan runs off the actor (media and ticks go on while it reads the disk) and is
    /// reused for `scanLifetimeNs` -> .claude/host.md § library
    func apps() async -> [GameApp] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let at = lifecycle.scannedAt, now &- at < Self.scanLifetimeNs { return lifecycle.scanned + config.extraGames }
        let library = library, epoch = lifecycle.libraryEpoch
        let scanned = await Task.detached(priority: .userInitiated) { library.scan() }.value
        await lifecycle.scanHold?()
        guard lifecycle.libraryEpoch == epoch else { return await apps() }  // the folders changed while it read the disk
        lifecycle.scanned = scanned
        lifecycle.scannedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return scanned + config.extraGames
    }

    func entries() async -> [GameEntry] {
        var apps = await apps()
        // A running game of a folder that was removed stays listed until it exits.
        if let g = game?.app, !apps.contains(where: { $0.titleID == g.titleID }) { apps.append(g) }
        await refreshArtwork(apps)
        let list = apps.map {
            GameEntry(titleID: $0.titleID, name: $0.name, streamable: $0.streamable,
                      state: $0.titleID == game?.app.titleID ? runState : .idle, art: artwork[$0.titleID]?.ref)
        }
        return list
    }

    /// The live session plays the running game (`resume`): the model resumes a paused one (an owed pause is just cleared);
    /// a session that only now plays is told the state and gets a key frame even when there was nothing to resume. With no
    /// game nothing plays: the session is told the Mac is idle and stays a library session.
    func play() {
        guard game != nil else { return sendState() }
        let was = model.playing
        let actions = model.resumeRequested(gameExists: true, at: self.now())
        if !was, game?.connected == true { configureTap() }  // the game takes the session's size and rate before it resumes
        perform(actions)
        guard !was, actions.isEmpty, liveLink != nil else { return }
        sendState()
        if game?.connected == true { tap.send(.keyframe) }
    }

    /// `id`: the link that asked; a launch that waited for the scan starts nothing for a link that has gone since. A session
    /// that does not play yet and launches the game that is starting or preparing (not paused) plays it, as `resume`; a
    /// paused game needs `resume`, and any other launch with a game present gets the running game as its reply.
    func launch(_ titleID: String, from id: Int) async {
        if let g = game {
            if !model.playing, g.app.titleID == titleID, runState != .paused { return play() }
            return sendState(reason: "\(g.app.name) is running")
        }
        let found = await apps().first(where: { $0.titleID == titleID })
        guard !stopped else { return }  // stop() ran during the scan: no game starts after it
        guard liveLink == id, links[id]?.admitted == true else { return }  // the device left (or was removed) during the scan
        if let g = game { return sendState(reason: "\(g.app.name) is running") }  // another launch won while the scan ran
        guard let app = found else {
            return sendState(titleID: titleID, run: .idle, reason: "not found")
        }
        guard app.streamable else { return sendState(titleID: titleID, run: .idle, reason: "rebuild needed") }
        model.launchRequested(at: self.now())
        generation += 1
        let gen = generation
        game = Game(app: app, generation: gen, launchedAt: self.now())
        game?.tracker.launched(now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        sendState()
        publishStatus()
        let environment = await launchEnvironment(for: app)
        guard game?.generation == gen, !stopped else { return }
        do {
            let running = try await config.launcher.launch(titleID: titleID, socketPath: tapSocketPath, environment: environment)
            guard game?.generation == gen, !stopped else { return await running.terminate() }
            game?.handle = running
            Task {
                let code = await running.waitForExit()
                self.gameExited(gen, code: code)
            }
        } catch {
            guard game?.generation == gen else { return }
            game = nil
            model.launchFailed()
            sendState(titleID: titleID, run: .idle, reason: "launch failed")
            publishStatus()
        }
    }

    private func gameExited(_ gen: Int, code: Int32) {
        guard !stopped, let g = game, g.generation == gen else { return }
        game = nil
        clearResends()
        tap.disconnect()  // a leftover child still connected must not hold the tap
        perform(model.gameExited(at: self.now()))
        sendState(titleID: g.app.titleID, run: .idle, reason: "exited (\(code))")
        publishStatus()
    }

    /// Ends the game without waiting for its exit (which is then ignored).
    private func abandonGame(reason: String) {
        guard let g = game else { return }
        game = nil
        clearResends()
        tap.disconnect()
        if let h = g.handle { Task { await h.terminate() } }
        perform(model.gameExited(at: self.now()))
        sendState(titleID: g.app.titleID, run: .idle, reason: reason)
        publishStatus()
    }

    public func quitGame() {
        guard !stopped else { return }
        guard game != nil else { return sendState() }
        tap.send(.quit)
        if game?.quitAt == nil { game?.quitAt = self.now() }
    }
}
#endif
