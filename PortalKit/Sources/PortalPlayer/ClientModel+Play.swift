import Foundation
import PortalKit
import PortalClientCore

/// Where `onPicture` lives, so the decode task reads it without the main actor.
final class PictureSink: @unchecked Sendable {
    private let lock = NSLock()  // guards _handler
    private var _handler: (@Sendable (DecodedFrame) -> Void)?
    var handler: (@Sendable (DecodedFrame) -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
}

/// Open while the screen is `.playing`: the session's frames and sound are dropped while it is shut.
final class PlayGate: @unchecked Sendable {
    private let lock = NSLock()  // guards _open, _soundOn
    private var _open = false
    private var _soundOn = true
    var soundOn: Bool {
        get { lock.withLock { _soundOn } }
        set { lock.withLock { _soundOn = newValue } }
    }
    var isOpen: Bool {
        get { lock.withLock { _open } }
        set { lock.withLock { _open = newValue } }
    }
}

/// How long the last decodes took (written by the decode task, read by the stats tick).
final class DecodeTimes: @unchecked Sendable {
    static let window = 120
    private let lock = NSLock()  // guards ms
    private var ms: [Double] = []
    private var second: [Double] = []  // since the recorder last took them
    func add(ns: UInt64) {
        lock.withLock {
            ms.append(Double(ns) / 1e6)
            if second.count < 600 { second.append(Double(ns) / 1e6) }
            if ms.count > Self.window { ms.removeFirst() }
        }
    }
    func median() -> Double {
        let sorted = lock.withLock { ms }.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    /// Mean and largest decode since the last call (the recorder's second); nil when none.
    func takeSecond() -> (meanMs: Double, maxMs: Double)? {
        lock.withLock {
            defer { second.removeAll(keepingCapacity: true) }
            guard let top = second.max() else { return nil }
            return (second.reduce(0, +) / Double(second.count), top)
        }
    }
    func reset() { lock.withLock { ms.removeAll(); second.removeAll() } }
}

/// A picture handed to the display: its capture time and the local time of the hand-off.
struct DisplayMark: Sendable { let captureNs: UInt64, atNs: UInt64 }

/// One open session with everything that lives as long as it does.
struct Link: Sendable {
    static let inputBuffer = 16
    let id: Int
    let session: ClientSession
    let decoder = VideoDecoder()
    let audio: AudioOutput?
    let gate = PlayGate()
    let decodeTimes = DecodeTimes()
    let input: AsyncStream<InputState>.Continuation
    let inputs: AsyncStream<InputState>
    let marks: AsyncStream<DisplayMark>.Continuation
    let marked: AsyncStream<DisplayMark>
    var tasks: [Task<Void, Never>] = []

    init(id: Int, session: ClientSession, audio: AudioOutput?) {
        self.id = id; self.session = session; self.audio = audio
        // Only the newest inputs matter (the session re-sends them every 8 ms); room for one neutral input per player.
        (inputs, input) = AsyncStream.makeStream(of: InputState.self, bufferingPolicy: .bufferingNewest(Self.inputBuffer))
        (marked, marks) = AsyncStream.makeStream(of: DisplayMark.self, bufferingPolicy: .unbounded)
    }

    func cancel() {
        gate.isOpen = false
        for t in tasks { t.cancel() }
        input.finish()
        marks.finish()
        audio?.stop()
    }
}

/// Playing: the decode and sound pumps, stats, input and the play calls -> .claude/client.md § model
extension ClientModel {
    static let statsInterval: UInt64 = 500_000_000
    static let overlayHoldNs: UInt64 = 1_000_000_000

    /// One long-lived task per session stream, off the main actor. A pump is never cancelled while its session
    /// is open (cancelling a `for await` ends the stream for good): the gate decides what is used.
    static func pumps(_ l: Link, _ sink: PictureSink) -> [Task<Void, Never>] {
        let session = l.session
        let frames = session.frames, audio = session.audio, inputs = l.inputs, marked = l.marked
        let decoder = l.decoder, gate = l.gate, output = l.audio, times = l.decodeTimes
        // The tasks hold the session only weakly: dropping the model releases it.
        let decoded: @Sendable (AssembledFrame) async -> Void = { [weak session] in await session?.frameDecoded($0) }
        let failed: @Sendable (AssembledFrame) async -> Void = { [weak session] in await session?.decodeFailed($0) }
        let send: @Sendable (InputState) async -> Void = { [weak session] in await session?.send($0) }
        let mark: @Sendable (DisplayMark) async -> Void = { [weak session] in
            await session?.markDisplayed(captureNs: $0.captureNs, at: $0.atNs)
        }
        return [
            Task { await decode(frames, decoder, gate, sink, times: times, decoded: decoded, failed: failed) },
            Task { await play(audio, output, gate) },
            Task { await forward(inputs, send) },
            Task { await forward(marked, mark) },
        ]
    }

    /// In order: not decodable -> `failed` (the session asks for a key frame), nothing shown; a picture -> `onPicture`,
    /// then `decoded` (the session acknowledges it to the Host) -> .claude/client.md § repair
    nonisolated static func decode(_ frames: AsyncStream<AssembledFrame>, _ decoder: VideoDecoder, _ gate: PlayGate,
                                   _ sink: PictureSink, times: DecodeTimes = DecodeTimes(),
                                   decoded: @escaping @Sendable (AssembledFrame) async -> Void = { _ in },
                                   failed: @escaping @Sendable (AssembledFrame) async -> Void) async {
        for await f in frames {
            guard gate.isOpen else { continue }
            await DecodeReport.step(f, decode: { decoder.decode($0) }, picture: { picture in
                times.add(ns: decoder.lastDecodeNs)
                sink.handler?(picture)
            }, decoded: decoded, failed: failed)
        }
    }

    /// Sound blocks to the output while open and sound is on (`soundOn`); drained either way (an unread stream grows without bound).
    nonisolated static func play(_ blocks: AsyncStream<AudioBlock>, _ output: AudioOutput?, _ gate: PlayGate) async {
        for await b in blocks where gate.isOpen && gate.soundOn { output?.push(b) }
    }

    nonisolated static func forward<T: Sendable>(_ values: AsyncStream<T>, _ to: @escaping @Sendable (T) async -> Void) async {
        for await v in values { await to(v) }
    }

    /// Entering `.playing`: the gate opens, sound starts, stats tick once a second.
    func startPlaying(_ l: Link) {
        guard !l.gate.isOpen else { return }
        l.gate.isOpen = true
        playersSent = []
        pictureShown = false
        displayShownFps = 0
        displayLate = 0
        latePictures = 0
        l.decodeTimes.reset()
        if l.gate.soundOn { try? l.audio?.start() }  // no sound is not a reason to stop the picture
        onInputWanted?()  // the Mac holds no input yet: a held button must reach it
        startRecording(l)
        statsTask?.cancel()
        let id = l.id
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.statsInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tickStats(link: id)
            }
        }
    }

    /// Leaving `.playing`: every player sent gets a neutral input (the session would re-send a held one into the
    /// next game), the gate shuts, the decoder resets, sound stops, stats stop.
    func stopPlaying(_ l: Link) {
        guard l.gate.isOpen else { return }
        for player in playersSent.sorted() {
            l.input.yield(Self.neutral(player))
        }
        playersSent = []
        lastInputs = [:]  // a press from this play must never reach the next game
        l.gate.isOpen = false
        l.decoder.reset()
        l.audio?.stop()
        statsTask?.cancel()
        statsTask = nil
        stopRecording()
        stats = nil
        playStats = nil
        pictureShown = false
    }

    func tickStats(link id: Int) async {
        guard let l = link, l.id == id else { return }
        _ = await refreshStats(l)
    }

    /// Fresh numbers now (also sets `stats` and the sound counters); nil when not playing.
    public func sampleStats() async -> SessionStats? {
        guard let l = link else { return nil }
        return await refreshStats(l)
    }

    /// A `load` older than this is not shown: the Host stopped sending it (the panel level changed, or the Mac is slow).
    static let loadFreshNs: UInt64 = 3_000_000_000

    private func refreshStats(_ l: Link) async -> SessionStats? {
        guard l.gate.isOpen else { return nil }
        let s = await l.session.stats()
        guard link?.id == l.id, l.gate.isOpen else { return nil }
        if stats != s { stats = s }
        soundUnderruns = l.audio?.underruns ?? 0
        soundLost = l.audio?.lostBlocks ?? 0
        var next = PlayStats(
            macFps: s.fps, shownFps: displayShownFps, late: displayLate, width: s.width, height: s.height,
            bitrateMbps: s.bitrateMbps, delayMs: s.p50DisplayMs, delayP95Ms: s.p95DisplayMs, rttMs: s.rttMs,
            gapP95Ms: s.p95ArrivalGapMs, gapMaxMs: s.maxArrivalGapMs, skipped: s.framesSkipped,
            keyRequests: s.keyRequests, sourceGaps: s.sourceGaps, decodeMs: l.decodeTimes.median(), soundBufferMs: l.audio?.targetMs ?? min(100, max(10, settings.audioBufferMs)), soundAuto: settings.audioBufferAuto,
            soundUnderruns: soundUnderruns, soundLost: soundLost, host: s.host,
            load: s.load.flatMap { uptimeNs() &- s.loadAtNs <= Self.loadFreshNs ? $0 : nil },
            rateMbps: Double(s.host?.rateBps ?? s.rateBps) / 1e6, ceilingMbps: Double(s.rateCeilingBps) / 1e6, rateCuts: s.rateCuts)
        next.fill(from: s, queueTarget: settings.picturePacing == .smooth ? FramePacer<DecodedFrame>.target : 0)
        if playStats != next { playStats = next }
        return s
    }

    // MARK: recorder

    static let recordInterval: UInt64 = 1_000_000_000
    /// A view report older than this is not this second's.
    static let reportFreshNs: UInt64 = 2_500_000_000

    /// Each play writes its numbers to a new file when `settings.recordSessions` and a folder were given -> `§ recorder`.
    /// The ticks run on the main actor only to read numbers; the file work is the recorder actor's.
    func startRecording(_ l: Link) {
        stopRecording()
        guard settings.recordSessions, let dir = recordingsDirectory else { return }
        let rec = SessionRecorder(directory: dir)
        let startNs = uptimeNs()
        displayReport = nil
        recorderTask = Task { [weak self] in
            // The file starts with the first line, so the header is built after the view had a second to report the display.
            var began = false
            loop: while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.recordInterval)
                guard !Task.isCancelled, let self else { break }
                let maxima = await l.session.takeSecondMaxima()
                switch self.recordLine(link: l, sinceNs: startNs, maxima: maxima) {
                case .over: break loop
                case .none: continue  // no numbers yet this second: the recording goes on
                case .line(let line):
                    if !began {
                        await rec.begin(header: self.recordHeader(titleID: self.gameState?.titleID).line)
                        began = true
                    }
                    await rec.append(line)
                }
            }
            await rec.end()
        }
    }

    func stopRecording() {
        recorderTask?.cancel()
        recorderTask = nil
    }

    func recordHeader(titleID: String?) -> SessionHeader {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let platform = "tvos"
        #elseif os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        return SessionHeader(
            app: info?["CFBundleShortVersionString"] as? String ?? "?", build: info?["CFBundleVersion"] as? String ?? "?",
            os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", platform: platform, model: DeviceModelName.machineIdentifier(),
            displayMaxHz: displayMaxHz, titleID: titleID, width: Int(settings.maxWidth), height: Int(settings.maxHeight),
            fpsCap: Int(settings.maxFps), bitrateMbps: settings.bitrateMbps, smooth: settings.picturePacing == .smooth,
            soundBuffer: settings.audioBufferAuto ? "auto" : "\(settings.audioBufferMs)")
    }

    enum RecordTick: Equatable { case over, none, line(String) }

    /// This second's line: `.over` when the play is (another link, gate shut), `.none` when its numbers are not there yet.
    func recordLine(link l: Link, sinceNs startNs: UInt64, maxima: SecondMaxima = SecondMaxima()) -> RecordTick {
        guard link?.id == l.id, l.gate.isOpen else { return .over }
        guard let s = stats, let play = playStats else { return .none }
        let now = uptimeNs()
        let report = displayReport.flatMap { now - $0.atNs <= Self.reportFreshNs ? $0.report : nil }
        let level = l.audio.map { $0.levelMs }
        let info = ProcessInfo.processInfo
        return .line(SessionSample.make(seconds: Double(now - startNs) / 1e9, stats: s, play: play, display: report, soundLevelMs: level,
                                  decode: l.decodeTimes.takeSecond(), thermal: info.thermalState.rawValue,
                                  lowPower: info.isLowPowerModeEnabled, maxima: maxima).line)
    }

    // MARK: calls

    /// The settings that need a new connection (stream size, frame rate) differ from the ones the open session was made with.
    public var pendingReconnect: Bool {
        guard let c = connectedWith else { return false }
        return c != ConnectionShape(width: settings.maxWidth, height: settings.maxHeight, fps: settings.maxFps)
    }

    /// The ceiling and the numbers level now, as the Host should have them.
    var liveNow: LiveSettings {
        LiveSettings(ceilingBps: helloBitrate,
                     panel: settings.statsLevel)
    }

    /// Sends the bitrate ceiling and numbers level to the Host (and the ceiling to the rate controller): in the order the
    /// changes were made, never blocking the caller. No session: nothing (the next one sends them when it opens).
    public func applyLive() {
        guard let l = link else { return }
        let live = liveNow, before = liveTask
        liveTask = Task {
            await before?.value
            try? await l.session.sendLive(live)  // a session that ended says so itself
        }
    }

    /// "Apply and reconnect": closes the session and opens it again to the same Mac with the settings as they are now. The
    /// Host pauses the game while the device is away and resumes it on the same device's return (the same game instance).
    public func reconnectApplying() async {
        guard let target, link != nil else { return }
        enterBusy()
        defer { leaveBusy() }
        let token = begin()
        let closing = teardown()
        await closing?.close()
        guard op == token else { return }
        switch await reopen(target, token: token, resume: playChosen) {
        case .done:
            if link != nil, !pictureShown { showsReconnecting = true }  // the first picture clears it
        case .stopped: break
        case .again:
            lostWhilePlaying()
            startRetry(target)
        }
    }

    /// `settings.playSound` changed: the open session's sound follows at once.
    func soundSettingChanged() {
        guard let l = link else { return }
        l.gate.soundOn = settings.playSound
        guard l.gate.isOpen else { return }
        if settings.playSound { try? l.audio?.start() } else { l.audio?.stop() }
    }

    /// Sends `launch`; the Host's `starting` state of that game confirms the play (`playChosen`) and moves the screen to
    /// `.playing`; a reply with a reason leaves the session as it was.
    public func launch(_ game: GameEntry) async {
        launchAsked = game.titleID
        lastPlayedTile = game.titleID
        if link != nil { playAsked = game.titleID }
        await call { try await $0.launch(titleID: game.titleID) }
    }

    /// Plays the paused, starting or running game (a library session's choice of it); the Host's running state of it confirms
    /// the play and moves the screen to `.playing`.
    public func resume() async {
        if link != nil { playAsked = gameState?.titleID ?? "" }
        await call { try await $0.resume() }
    }

    /// Asks the Host to quit; its `idle` state moves the screen to `.library`. None within 6 s -> `quitUnconfirmed`.
    public func quitGame() async {
        guard let l = link else { return }
        quitTask?.cancel()
        quitAsked = true
        do { try await l.session.quitGame() } catch {
            guard link?.id == l.id else { return }  // a newer action reset `quitAsked`
            quitAsked = false
            callFailed(error, link: l.id)
            return
        }
        guard quitAsked, link?.id == l.id else { return }  // the idle state already came, or the session is gone
        message = nil
        let wait = UInt64(quitWait * 1e9)
        quitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self, self.quitAsked else { return }
            self.quitAsked = false
            self.quitTask = nil
            self.message = Messages.quitUnconfirmed
        }
    }

    /// To the session while playing; only the newest input waits (the session re-sends it every 8 ms). While `stalled`
    /// the game gets a neutral input instead (a held button must not stay held on the Mac while the picture is frozen);
    /// the real one is kept and sent when the link is back.
    public func send(_ input: InputState) {
        guard screen == .playing, let l = link, l.gate.isOpen else { return }
        playersSent.insert(input.player)
        lastInputs[input.player] = input
        _ = l.input.yield(stalled ? Self.neutral(input.player) : input)
    }

    static func neutral(_ player: UInt8) -> InputState {
        InputState(seq: 0, player: player, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil)
    }

    /// Keeps `preparing` and `preparingSince` from the Host's state; the Host never reports it for a paused game.
    func notePreparing(_ state: GameState) {
        let now = preparing == nil && state.preparing != nil ? Date() : preparingSince
        preparing = state.preparing
        preparingSince = state.preparing == nil ? nil : now
    }

    /// The Mac's live preparing for `titleID` (the session's newest state, in play and in the library); nil for another game
    /// or with no session.
    public func preparing(for titleID: String) -> Preparing? {
        gameState?.titleID == titleID ? preparing : nil
    }

    /// The session's `stalls`: the picture is frozen and the sound silent while it lasts; the game gets neutral input,
    /// and the held input again once the link is back (the session has asked for a refresh by then).
    func setStalled(_ on: Bool, link id: Int) {
        guard let l = link, l.id == id, stalled != on else { return }
        stalled = on
        overlayTask?.cancel()
        if on {
            showsReconnecting = true
        } else {
            // Gone with the first new picture shown, or a second after recovery: a lone pong must not clear it over a frozen picture.
            overlayTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.overlayHoldNs)
                guard !Task.isCancelled else { return }
                self?.showsReconnecting = false
            }
        }
        l.audio?.flush()  // no looping of the last block now, no burst of stale blocks after
        guard l.gate.isOpen else { return }
        if on {
            for player in playersSent.sorted() { l.input.yield(Self.neutral(player)) }
        } else {
            // The controller reports changes only: what is held through the stall must be sent again, and what was
            // released during it arrives as the neutral input it is.
            for player in playersSent.sorted() { if let input = lastInputs[player] { l.input.yield(input) } }
        }
    }

    /// The view handed the picture captured at `captureNs` to the display at local `at` (`uptimeNs()`, taken on
    /// the main queue right after the enqueue) -> `SessionStats.framesDisplayed`, `p95DisplayMs`; sets `pictureShown`.
    public func picturesShown(captureNs: UInt64, at: UInt64) {
        guard let l = link else { return }
        l.marks.yield(DisplayMark(captureNs: captureNs, atNs: at))
        if showsReconnecting, !stalled {
            showsReconnecting = false  // the first picture after recovery
            overlayTask?.cancel()
        }
        if !pictureShown { pictureShown = true }
    }

    /// The view's pacer counts over `seconds` (about one second): the next `playStats` carries them as a rate.
    public func displayCounts(shown: Int, late: Int, empty: Int, seconds: Double, pending: Int = 0, phase: PhaseSummary? = nil) {
        latePictures += late
        if seconds > 0 {
            var r = DisplayReport()
            r.shown = shown; r.late = late; r.empty = empty; r.pending = pending; r.phase = phase
            displayReport = (r, uptimeNs())
        }  // a dropped window (`seconds` 0) keeps its pictures in the total
        guard seconds > 0 else { return }
        displayShownFps = Double(shown) / seconds
        displayLate = Double(late) / seconds
    }

    /// The outcome counts only for the session the call was made on.
    private func call(_ body: (ClientSession) async throws -> Void) async {
        guard let l = link else {
            if reconnecting { message = Messages.busyReconnecting }  // a tap with no link must not be silent
            return
        }
        do {
            try await body(l.session)
            succeeded(link: l.id)
        } catch {
            if link?.id == l.id { launchAsked = nil; playAsked = nil }  // no answer is coming for an ask that failed
            callFailed(error, link: l.id)
        }
    }
}
