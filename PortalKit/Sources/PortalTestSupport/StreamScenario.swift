#if os(macOS)
import Foundation
import Network
import PortalKit
import PortalHostCore
import PortalClientCore

/// What a scenario measured -> .claude/portalkit.md § test-network
public struct ScenarioResult: Sendable {
    /// What the fake game sent (padded to the bitrate) in the measured window.
    public var framesSent: Int
    /// Frames that came out of the session's `frames` stream in the same window.
    public var framesOut: Int
    /// Frame numbers never went backwards (a gap is allowed).
    public var inOrder: Bool
    /// Longest time without a frame out of the session in the window, the tail to the end included (no frame at all = the window), ignoring the first second.
    public var longestGapMs: Double
    /// Key frames out of the session.
    public var keyFrames: Int
    public var stats: SessionStats
    /// Host to client datagrams the shaper passed on, and lost (loss and tail drop).
    public var forwarded: Int
    public var dropped: Int
    /// The session had not ended when the scenario did.
    public var alive: Bool
    /// What the Host told the game, one line each (`config 1280x720@60 20000000`, `keyframe`, `pause on`).
    public var hostLog: [String]
    /// The shaper's seed (the profile's own when it carries one: `LinkProfile.random(seed:)`), and what a `random` profile did:
    /// `LinkShaper.events`, on the same clock as `frameTimes` (`CLOCK_UPTIME_RAW`, ns).
    public var seed: UInt64
    public var events: [LinkShaper.Event]
    /// When each frame came out of the session, over the whole run, and the measured window.
    public var frameTimes: [UInt64]
    public var windowStartNs: UInt64, windowEndNs: UInt64
    /// The largest overshoot (ms) of a 1 ms ticker in this process from the session's `open` to the window's end (the whole
    /// span the session's counts, `nacksSent` among them, cover: launch, the first key frame and the window): how
    /// long the test process itself was not scheduled. A run with a large one saw holes that no link caused; see
    /// `ScenarioTests.unstarved`.
    public var stallMs: Double = 0
    /// When the largest one ended (`CLOCK_UPTIME_RAW` ns, the clock of `frameTimes`), and every overshoot of 2 ms or more with
    /// the time it ended: `worstStall(excluding:)` leaves out a stretch where nothing can be asked for again.
    public var stallAtNs: UInt64 = 0
    public var stallEvents: [(atNs: UInt64, ms: Double)] = []
    /// The largest overshoot (ms) that did not lie inside any of `quiet` (start, end in ns): a link cut in both directions
    /// delivers nothing, so a scheduling stall in it cannot make the client see a hole. 0 when none is left.
    public func worstStall(excluding quiet: [(from: UInt64, to: UInt64)]) -> (atNs: UInt64, ms: Double)? {
        stallEvents.filter { e in
            let start = e.atNs - min(e.atNs, UInt64(e.ms * 1e6))
            return !quiet.contains { start >= $0.from && e.atNs <= $0.to }
        }.max { $0.ms < $1.ms }
    }
    /// The Host's sender: slices served, and how late they left against their schedule (us, 95th percentile and worst).
    public var senderSlices: Int, senderLateP95Us: Int, senderLateMaxUs: Int
    /// Every change of the session's `stalled` (when, on the clock of `frameTimes`, and the new value).
    public var stallChanges: [(atNs: UInt64, on: Bool)]
    /// Why and when the session ended on its own (nil while alive), and when the Host let the client go (it pauses the game).
    public var clientEnd: SessionEnd?, clientEndNs: UInt64?, hostPausedNs: UInt64?
    /// Nacks the session had sent when `midway` ran and at the end of the run.
    public var nacksAtMidway: Int
    /// The capture time (Host clock, the same uptime clock) of each frame that came out, in `frameTimes` order, and each sound
    /// block that came out with when it did.
    public var frameCaptures: [UInt64]
    public var audioBlocks: [(captureNs: UInt64, atNs: UInt64)]
    /// The rate the session asked for over the run (its start, then every change, on the clock of `frameTimes`;
    /// empty when the rate is fixed), and its cuts.
    public var rateTrace: [(atNs: UInt64, bps: UInt32)]
    public var cuts: Int
    /// Frames the game had sent, sampled every 10 ms over the run (time, total).
    public var sentTrace: [(atNs: UInt64, total: Int)]
    /// Repair frames out of the session; frames the scenario's decoder could not decode (0 without a decoder).
    public var repairFrames: Int, decodeErrors: Int
    /// `ltrAck` messages the game got from the Host (each one acknowledgement).
    public var ltrAcks: Int
    /// Every token the game got in an `ltrAck`, in order; the token the game gave each frame it sent (its last 600).
    public var ackedTokens: [Int32], tokens: [UInt32: Int32]
    /// Median sizes (bytes) of what the game sent: ordinary, repair and key frames (the Host's counts; 0 = none).
    public var medianBytes: (ordinary: Int, repair: Int, key: Int)
    /// `refresh` messages the game served with a key or repair frame already due (it sent no new one for them).
    public var refreshesCoalesced = 0
    /// Frames sent and frames out between two times in seconds from the window's start (sent by the game's count at
    /// those times, out by `frameTimes`).
    public func counts(fromSeconds a: Double, toSeconds b: Double) -> (sent: Int, out: Int) {
        let from = windowStartNs + UInt64(max(0, a) * 1e9), to = min(windowStartNs + UInt64(max(0, b) * 1e9), windowEndNs)
        func sentBy(_ t: UInt64) -> Int { sentTrace.last { $0.atNs <= t }?.total ?? 0 }
        return (sentBy(to) - sentBy(from), frameTimes.filter { $0 > from && $0 <= to }.count)
    }
    /// Cuts (a rate lower than the one before) between two times in seconds from the window's start.
    public func cuts(fromSeconds a: Double, toSeconds b: Double = .infinity) -> Int {
        let from = Double(windowStartNs) + a * 1e9, to = Double(windowStartNs) + b * 1e9
        return zip(rateTrace, rateTrace.dropFirst()).filter { $1.bps < $0.bps && Double($1.atNs) > from && Double($1.atNs) <= to }.count
    }
    /// The rate (bit/s) at `t` (the newest entry of `rateTrace` at or before it; 0 when none).
    public func rate(at t: UInt64) -> UInt32 { rateTrace.last { $0.atNs <= t }?.bps ?? 0 }
    /// `rate start=<Mbit/s> low=<> end=<> cuts=<n> trace=<s from the window's start>:<Mbit/s>,…`
    public var rateLine: String {
        guard let first = rateTrace.first else { return "rate fixed" }
        func m(_ b: UInt32) -> String { String(format: "%.1f", Double(b) / 1e6) }
        let trace = rateTrace.map { String(format: "%.1f", (Double($0.atNs) - Double(windowStartNs)) / 1e9) + ":" + m($0.bps) }
        return "rate start=\(m(first.bps)) low=\(m(rateTrace.map(\.bps).min() ?? 0)) end=\(m(rate(at: windowEndNs))) cuts=\(cuts) trace="
            + trace.joined(separator: ",")
    }
    /// `scenario <name>: out=<framesOut>/<framesSent> gap=<longestGapMs> key=<keyFrames> repair=<repairFrames>
    /// esc=<escalations> decodeErr=<decodeErrors>`
    public func line(_ name: String) -> String {
        String(format: "scenario %@: out=%d/%d gap=%.0f key=%d repair=%d esc=%d decodeErr=%d", name, framesOut, framesSent,
               longestGapMs, keyFrames, repairFrames, stats.escalations, decodeErrors)
    }
}

/// Fake game -> `HostService` -> `LinkShaper` -> `ClientSession`, all in-process over loopback -> .claude/portalkit.md § test-network
public enum StreamScenario {
    private final class Arrivals: @unchecked Sendable {
        private let lock = NSLock()  // guards every var below
        private var numbers: [UInt32] = []
        private var times: [UInt64] = []
        private var keys = 0, repairs = 0, errors = 0
        private var caps: [UInt64] = []
        func decodeError() { lock.lock(); errors += 1; lock.unlock() }
        var decodeErrors: Int { lock.lock(); defer { lock.unlock() }; return errors }
        var repairFrames: Int { lock.lock(); defer { lock.unlock() }; return repairs }
        private var audio: [(captureNs: UInt64, atNs: UInt64)] = []
        func block(_ b: AudioBlock) { lock.lock(); audio.append((b.captureNs, clock_gettime_nsec_np(CLOCK_UPTIME_RAW))); lock.unlock() }
        var audioBlocks: [(captureNs: UInt64, atNs: UInt64)] { lock.lock(); defer { lock.unlock() }; return audio }
        var captures: [UInt64] { lock.lock(); defer { lock.unlock() }; return caps }
        private var stalls: [(atNs: UInt64, on: Bool)] = []
        private var endNs: UInt64?, pausedNs: UInt64?
        func stall(_ on: Bool) { lock.lock(); stalls.append((clock_gettime_nsec_np(CLOCK_UPTIME_RAW), on)); lock.unlock() }
        func ended() { lock.lock(); if endNs == nil { endNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }; lock.unlock() }
        func paused() { lock.lock(); if pausedNs == nil { pausedNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }; lock.unlock() }
        var events: (stalls: [(atNs: UInt64, on: Bool)], endNs: UInt64?, pausedNs: UInt64?) {
            lock.lock(); defer { lock.unlock() }; return (stalls, endNs, pausedNs)
        }
        func add(_ f: AssembledFrame) {
            lock.lock(); caps.append(f.captureNs); numbers.append(f.frame); times.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)); if f.key { keys += 1 }; if f.repair { repairs += 1 }; lock.unlock()
        }
        var snapshot: (numbers: [UInt32], times: [UInt64], keys: Int) { lock.lock(); defer { lock.unlock() }; return (numbers, times, keys) }
        private var rates: [(atNs: UInt64, bps: UInt32)] = []
        func rate(_ bps: UInt32) {
            lock.lock(); if rates.last?.bps != bps { rates.append((clock_gettime_nsec_np(CLOCK_UPTIME_RAW), bps)) }; lock.unlock()
        }
        var rateTrace: [(atNs: UInt64, bps: UInt32)] { lock.lock(); defer { lock.unlock() }; return rates }
        private var sentTotals: [(atNs: UInt64, total: Int)] = []
        func sent(_ n: Int) { lock.lock(); if sentTotals.last?.total != n { sentTotals.append((clock_gettime_nsec_np(CLOCK_UPTIME_RAW), n)) }; lock.unlock() }
        var sentTrace: [(atNs: UInt64, total: Int)] { lock.lock(); defer { lock.unlock() }; return sentTotals }
    }

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    /// Streams `seconds` (from the first frame out) through `profile`. `bitrateMbps` is the client's wish: the ceiling the
    /// session's rate controller steers under (`adaptiveRate`, the default), else the fixed rate; `paceMs` the Host's (0 = each frame at once).
    /// `profileChanges`: the shaper's profile is set to each at its time (seconds from the window's start). `load`: how the
    /// fake game's frame sizes change over time (`FakeGame.Load`).
    /// `silenceTimeout`: the client's silence limit, and the Host's too unless `hostSilenceTimeout` is given (a test that needs one
    /// side to end first: equal limits leave the order to the Host's 100 ms tick).
    /// `midway` runs once, half way through the window, with the shaper (a test that cuts the link there).
    /// `decoder`: makes the player's decoder for the run (a frame in, decoded or not out); each frame out of the session
    /// goes through it and the session hears `frameDecoded` or `decodeFailed`, as from the app. Without one nothing is
    /// acknowledged (the game then repairs with key frames). `dropVideo`: fragments dropped on arrival as if lost.
    /// `repairDelay`, `longTermReferences`: the fake game's (`FakeGame.init`).
    /// `consume`: instead of `decoder`, a loop that takes every frame the session yields (after it is counted) and reports
    /// to the session itself, as `portal-fakeclient --decode` does.
    /// `framesSent` and `framesOut` count from the start of the window; `keyFrames` and `inOrder` over the whole run.
    public static func run(decoder: (@Sendable () -> @Sendable (AssembledFrame) -> Bool)? = nil,
                           profile: LinkProfile, seconds: Double, bitrateMbps: Int = 20, adaptiveRate: Bool = true,
                           profileChanges: [(atSeconds: Double, profile: LinkProfile)] = [], load: FakeGame.Load = .bitrate,
                           fps: Int = 60, seed: UInt64 = 1,
                           paceMs: Double = HostConfig.defaultPaceMs, silenceTimeout: TimeInterval = ClientSession.defaultSilenceTimeout,
                           hostSilenceTimeout: TimeInterval? = nil,
                           midway: (@Sendable (LinkShaper) -> Void)? = nil,
                           sessionMidway: (@Sendable (ClientSession) -> Void)? = nil,
                           dropVideo: (@Sendable (VideoFragment) -> Bool)? = nil,
                           repairDelay: Int = 1, longTermReferences: Bool = true,
                           consume: (@Sendable (ClientSession, AsyncStream<AssembledFrame>) async -> Void)? = nil,
                           configure: (inout HostConfig) -> Void = { _ in }) async throws -> ScenarioResult {
        let fakeID = "FAKE000000000000"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-s-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tapPath = "/tmp/nxp-s-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)) + ".sock"  // one per Host
        defer { try? FileManager.default.removeItem(atPath: tapPath) }
        let launcher = FakeLauncher(fps: fps, paddedToBitrate: true, load: load, repairDelay: repairDelay,
                                    longTermReferences: longTermReferences)
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        var config = HostConfig(name: "Scenario Host", storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
                                launcher: launcher, power: NoPower(), advertise: false, port: 0, extraGames: [fake])
        config.tapSocketPath = tapPath
        config.paceMs = paceMs
        config.silenceTimeout = hostSilenceTimeout ?? silenceTimeout  // the same limit unless a test orders the two
        configure(&config)
        let service = try HostService(config: config)
        let controlPort = try await service.start()

        let shaper = LinkShaper(profile: profile, seed: seed, to: ("127.0.0.1", 0))
        let arrivals = Arrivals()
        var session: ClientSession?
        var consumer: Task<Void, Never>?, watcher: Task<Void, Never>?, watcherExtra: Task<Void, Never>?, consumeTask: Task<Void, Never>?
        var script: Task<Void, Never>?, ticker: Task<Void, Never>?
        let ticks = StallMeter()
        func finish() async {
            await session?.close()
            shaper.stop()
            launcher.game?.stop()
            await service.stop()
            consumer?.cancel()
            watcher?.cancel()
            watcherExtra?.cancel()
            consumeTask?.cancel()
            ticker?.cancel()
            script?.cancel()
        }
        let windowStart: UInt64, windowEnd: UInt64, sentAtStart: Int, outAtStart: Int
        let stats: SessionStats, alive: Bool
        var nacksAtMidway = 0
        var clientEndReason: SessionEnd?
        do {
            let shaperPort = try shaper.start()
            let s = ClientSession(identity: Identity(), name: "Scenario Client", kind: .tool, maxWidth: 1280, maxHeight: 720,
                                  maxFps: UInt8(fps), bitrate: UInt32(bitrateMbps) * 1_000_000, adaptiveRate: adaptiveRate,
                                  silenceTimeout: silenceTimeout,
                                  mediaVia: ("127.0.0.1", shaperPort), mediaPortKnown: { shaper.setHostPort($0) })
            session = s
            if let dropVideo { await s.dropVideo(dropVideo) }
            let frames = s.frames
            let decode = decoder?()
            let (forwarded, forward) = AsyncStream.makeStream(of: AssembledFrame.self, bufferingPolicy: .unbounded)
            if let consume { consumeTask = Task { await consume(s, forwarded) } } else { forward.finish() }
            consumer = Task {
                defer { forward.finish() }
                for await f in frames {
                    arrivals.add(f)
                    if consume != nil { forward.yield(f) }
                    guard let decode else { continue }
                    await DecodeReport.step(f, decode: { decode($0) ? () : nil },
                                            decoded: { await s.frameDecoded($0) },
                                            failed: { arrivals.decodeError(); await s.decodeFailed($0) })
                }
            }
            let audioStream = s.audio
            let audioWatcher = Task { for await b in audioStream { arrivals.block(b) } }
            watcherExtra = audioWatcher
            let stalls = s.stalls
            let stallWatcher = Task { for await on in stalls { arrivals.stall(on) } }
            let game = { launcher.game }
            // When the session ends by itself and when the Host pauses the game for a client that left.
            watcher = Task {
                while !Task.isCancelled {
                    if let r = await s.currentRate { arrivals.rate(r) }
                    if let n = game()?.framesSent { arrivals.sent(n) }
                    if await s.end != nil { arrivals.ended() }
                    if game()?.received.contains(.pause(true)) == true { arrivals.paused() }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                stallWatcher.cancel()
            }
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: controlPort)!)
            let code = try await service.beginPairing()
            try await s.connect(to: endpoint)
            let host = try await s.pair(code: code)
            // Media (and so anything the session counts, `nacksSent` among them) starts at `open`: the pairing and the TCP
            // connect before it cannot raise a nack.
            ticker = Task { await Self.tick(into: ticks) }
            try await s.open(host: host)
            try await s.launch(titleID: fakeID)
            // Like the app: a pad state from the start, which the session re-sends every 8 ms (the client to Host
            // lane then carries what a real one does; a loss run counted in datagrams is not a 1 s blackout).
            await s.send(InputState(seq: 0, player: 0, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil))
            // The window starts with the first frame, or after 5 s without one (a link that never lets a key frame through).
            let giveUp = Date().addingTimeInterval(5)
            while arrivals.snapshot.numbers.isEmpty, Date() < giveUp { try await Task.sleep(nanoseconds: 5_000_000) }
            windowStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let changes = profileChanges.sorted { $0.atSeconds < $1.atSeconds }
            script = Task {
                for c in changes {
                    let due = windowStart + UInt64(max(0, c.atSeconds) * 1e9), now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    if due > now { try? await Task.sleep(nanoseconds: due - now) }
                    if Task.isCancelled { return }
                    shaper.setProfile(c.profile)
                }
            }
            sentAtStart = launcher.game?.framesSent ?? 0
            outAtStart = arrivals.snapshot.numbers.count
            try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
            nacksAtMidway = await s.stats().nacksSent
            midway?(shaper)
            sessionMidway?(s)
            try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
            windowEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            ticker?.cancel()
            stats = await s.stats()
            clientEndReason = await s.end
            alive = clientEndReason == nil
        } catch {
            await finish()
            throw error
        }
        let counts = shaper.counts
        let events = shaper.events
        let late = await service.senderLateness
        let sizes = await service.frameSizeMedians
        let sent = (launcher.game?.framesSent ?? 0) - sentAtStart
        let received = launcher.game?.received ?? []
        let log = received.compactMap(describe)
        let ltrAcks = received.filter { if case .ltrAck = $0 { true } else { false } }.count
        let ackedTokens = received.flatMap { m -> [Int32] in if case let .ltrAck(t) = m { t } else { [] } }
        let tokens = (launcher.game?.sentFrames ?? [:]).mapValues(\.token)
        let coalesced = launcher.game?.refreshesCoalesced ?? 0
        let (numbers, times, keys) = arrivals.snapshot
        let observed = arrivals.events
        await finish()

        // Frames after the window's end (they arrive while the stats are read) are not counted anywhere.
        let inWindow = times.prefix { $0 <= windowEnd }.count
        var inOrder = true
        for (a, b) in zip(numbers, numbers.dropFirst()) where b <= a { inOrder = false }
        let longest = longestGapMs(times: times, windowStart: windowStart, windowEnd: windowEnd)
        var result = ScenarioResult(framesSent: sent, framesOut: max(0, inWindow - outAtStart), inOrder: inOrder, longestGapMs: longest,
                              keyFrames: keys, stats: stats, forwarded: counts.forwarded, dropped: counts.dropped, alive: alive, hostLog: log,
                              seed: shaper.seed, events: events, frameTimes: times, windowStartNs: windowStart, windowEndNs: windowEnd, stallMs: ticks.maxMs,
                              senderSlices: late.slices, senderLateP95Us: late.p95Us, senderLateMaxUs: late.maxUs,
                              stallChanges: observed.stalls, clientEnd: clientEndReason, clientEndNs: observed.endNs,
                              hostPausedNs: observed.pausedNs, nacksAtMidway: nacksAtMidway,
                              frameCaptures: arrivals.captures, audioBlocks: arrivals.audioBlocks,
                              rateTrace: arrivals.rateTrace, cuts: stats.rateCuts, sentTrace: arrivals.sentTrace,
                              repairFrames: arrivals.repairFrames, decodeErrors: arrivals.decodeErrors, ltrAcks: ltrAcks,
                              ackedTokens: ackedTokens, tokens: tokens, medianBytes: (sizes.ordinary, sizes.repair, sizes.key),
                              refreshesCoalesced: coalesced)
        result.stallAtNs = ticks.maxAtNs
        result.stallEvents = ticks.events
        return result
    }

    /// A 1 ms ticker on the continuous clock; the largest overshoot is what the meter keeps.
    private static func tick(into meter: StallMeter) async {
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
            let now = clock.now
            let d = now - last - .milliseconds(1)
            meter.add(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15, atNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            last = now
        }
    }

    /// Longest time without a frame between `windowStart + skipNs` and `windowEnd`, the tail to `windowEnd` included;
    /// times outside the window (or out of order) never underflow.
    public static func longestGapMs(times: [UInt64], windowStart: UInt64, windowEnd: UInt64,
                                    skipNs: UInt64 = 1_000_000_000) -> Double {
        let from = windowStart + skipNs
        guard windowEnd > from else { return 0 }
        var longest: UInt64 = 0
        var previous = from
        for t in times + [windowEnd] where t > previous && t <= windowEnd {
            longest = max(longest, t - previous)
            previous = t
        }
        return Double(longest) / 1e6
    }

    private static func describe(_ m: TapMessage) -> String? {
        switch m {
        case let .config(w, h, f, b): "config \(w)x\(h)@\(f) \(b)"
        case .keyframe: "keyframe"
        case .refresh: "refresh"
        case let .pause(on): "pause \(on ? "on" : "off")"
        case .quit: "quit"
        default: nil
        }
    }
}
/// The largest overshoot seen by the scenario's ticker (ms).
final class StallMeter: @unchecked Sendable {
    private let lock = NSLock()  // guards max
    private var max = 0.0, maxAt: UInt64 = 0
    private var kept: [(atNs: UInt64, ms: Double)] = []
    func add(_ ms: Double, atNs: UInt64) {
        lock.withLock {
            if ms > max { max = ms; maxAt = atNs }
            if ms >= 2 { kept.append((atNs, ms)) }
        }
    }
    var maxMs: Double { lock.withLock { max } }
    var maxAtNs: UInt64 { lock.withLock { maxAt } }
    var events: [(atNs: UInt64, ms: Double)] { lock.withLock { kept } }
}
#endif
