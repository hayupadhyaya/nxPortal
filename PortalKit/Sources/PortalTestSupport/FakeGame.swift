#if os(macOS)
import Foundation
import PortalKit
import PortalHostCore

public enum FakeGameError: Error, Equatable { case connect(Int32), pathTooLong }

/// Speaks the tap socket protocol (2) with real HEVC video and a 440 Hz tone -> .claude/host.md § test-support
/// Long-term references as the tap does them (tokens with an epoch, `ltrAck`, `refresh` -> a repair frame or a key
/// frame, the flags byte): `repairDelay` ordinary frames go out after a `refresh` before the repair frame (they were
/// in flight when the game read it); a `refresh` while a repair or key frame is still due is served by it.
/// `paddedToBitrate`: each frame gets filler so its size follows the configured bitrate (bitrate / 8 / fps, a key
/// frame 4 times that); for scenarios that need realistic traffic -> .claude/portalkit.md § test-network
/// `load` changes that size over time (from the first frame), for scenarios where the picture, not the link, changes.
public final class FakeGame: @unchecked Sendable {
    public enum Load: Sendable, Equatable {
        /// Every frame follows the bitrate.
        case bitrate
        /// Frames of 0.1 Mbit/s (a still menu, whatever the config) until this many seconds, then the bitrate.
        case quietUntil(seconds: Double)
        /// Half the bitrate in even seconds, the whole in odd ones: frames double in size every other second.
        case halfEveryOtherSecond
    }

    private struct Config { var maxWidth: Int, maxHeight: Int, maxFps: Int, bitrate: Int }
    /// What the game sent for a frame (the newest 600).
    public struct SentFrame: Sendable, Equatable { public var mark: FrameMark, token: Int32, bytes: Int }
    /// The tap's long-term-reference state -> .claude/tap.md § ltr (`stream_video_mac.m`), under `lock`.
    private struct Ltr {
        static let issuedMax = 64, pendingMax = 32
        var on = false, acked = false, keyWait = 0, fixWait = 0, epoch: Int32 = 0
        var issued: [Int32] = [], pending: [Int32] = []
        /// Ordinary frames still to go out before the repair frame (nil: no refresh asked).
        var refreshIn: Int?
    }

    private let socketPath: String
    private let titleID: String
    private let name: String
    private let width: Int
    private let height: Int
    private let fps: Int
    private let version: UInt16
    private let padded: Bool
    private let load: Load
    private let repairDelay: Int
    private let wantLTR: Bool
    private let preparePhases: [UInt32]
    private let prepareSteps: [PrepareStep]
    private let stall: TimeInterval
    private let solid: UInt32?
    /// When the first frame was delivered (the time base of `load`).
    private var loadStartNs: UInt64?

    private let lock = NSLock()  // guards every var below
    private var fd: Int32 = -1
    private var stopping = false
    private var ended = false
    private var exit: Int32 = 0
    private var config: Config?
    private var configGeneration = 0
    private var paused = false
    /// A game that does not act on `quit` (the Host's grace ends it).
    public var ignoresQuit = false
    private var forceKey = false
    private var nextFrame: UInt32 = 0
    private var finished = false
    private var _received: [TapMessage] = []
    private var lastButtons: UInt64 = 0
    private var _onButtons: (@Sendable (UInt64) -> Void)?
    private var _sentVideo: [UInt32: Data] = [:]
    private var _sentFrames: [UInt32: SentFrame] = [:]
    private var ltr = Ltr()
    private var _repairsAnsweredWithKey = 0
    private var _refreshesCoalesced = 0
    private let writeLock = NSLock()  // serializes socket writes and frame numbering
    private let workers = DispatchGroup()

    /// One `prepare` message as the tap sends it.
    public struct PrepareStep: Equatable, Sendable {
        public var phase: UInt8, done: UInt32, total: UInt32
        public init(phase: UInt8, done: UInt32, total: UInt32) { self.phase = phase; self.done = done; self.total = total }
    }

    /// `repairDelay`: ordinary frames sent after a `refresh` before its repair frame. `longTermReferences` false: as a
    /// tap whose encoder refused them (tokens -1, a refresh is a key frame).
    /// `preparePhases`: before its first frame the game sends `prepare` for each phase (1, 2, ...) with that total: start,
    /// half way, done, 20 ms apart. `prepareSteps`: the explicit `prepare` messages to send instead of `preparePhases`'
    /// (a test's own values). `stall` (seconds): the preparation takes this long before the first frame, its messages
    /// spread evenly over it; with no phases or steps given it sends phase 1 at 100, 600 and 1000 of 1000. `solidColor`
    /// (ARGB): every picture is that colour instead of cycling red, green and blue (screenshots over a white picture).
    public init(socketPath: String, titleID: String = "FAKE000000000000", name: String = "Fake Game",
                width: Int = 1280, height: Int = 720, fps: Int = 60, version: UInt16 = ProtocolVersion.tap,
                paddedToBitrate: Bool = false, load: Load = .bitrate, repairDelay: Int = 1, longTermReferences: Bool = true,
                preparePhases: [UInt32] = [], prepareSteps: [PrepareStep] = [], stall: TimeInterval = 0, solidColor: UInt32? = nil) {
        self.prepareSteps = prepareSteps; self.stall = max(0, stall); self.solid = solidColor
        self.padded = paddedToBitrate; self.load = load
        self.repairDelay = max(0, repairDelay); self.wantLTR = longTermReferences; self.preparePhases = preparePhases
        self.socketPath = socketPath; self.titleID = titleID; self.name = name
        self.width = width; self.height = height; self.fps = fps; self.version = version
    }

    /// Called on the reader thread with player 0's buttons whenever they change (starts from 0).
    public var onButtons: (@Sendable (UInt64) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onButtons }
        set { lock.lock(); _onButtons = newValue; lock.unlock() }
    }
    /// Frames handed to the socket so far.
    public var framesSent: Int { lock.lock(); defer { lock.unlock() }; return Int(nextFrame) }
    public var received: [TapMessage] { lock.lock(); defer { lock.unlock() }; return _received }
    public var sentVideo: [UInt32: Data] { lock.lock(); defer { lock.unlock() }; return _sentVideo }
    /// The mark, token and size of each frame sent (the newest 600).
    public var sentFrames: [UInt32: SentFrame] { lock.lock(); defer { lock.unlock() }; return _sentFrames }
    /// Refreshes the encoder answered with a key frame although asked for a repair frame (the tap's guard; must stay 0).
    public var repairsAnsweredWithKey: Int { lock.lock(); defer { lock.unlock() }; return _repairsAnsweredWithKey }
    /// `refresh` messages that found a key or repair frame already due or in the encoder and were served by it.
    public var refreshesCoalesced: Int { lock.lock(); defer { lock.unlock() }; return _refreshesCoalesced }
    public var exitCode: Int32 { lock.lock(); defer { lock.unlock() }; return exit }
    /// `run()` has returned (or is about to).
    public var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    public func stop(exitCode: Int32 = 0) {
        lock.lock(); defer { lock.unlock() }
        stopping = true
        exit = exitCode
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    /// Connects, says hello, then streams until `quit`, the Host closing the socket, or `stop()`.
    public func run() async throws {
        defer { markFinished() }
        if isStopping { return }
        let sock = try connectSocket()
        guard adopt(sock) else { close(sock); return }
        send(.hello(version: version, titleID: titleID, name: name))
        var steps = prepareSteps
        if steps.isEmpty {
            for (i, total) in preparePhases.enumerated() {
                for done in [0, total / 2, total] { steps.append(PrepareStep(phase: UInt8(i + 1), done: done, total: total)) }
            }
        }
        if steps.isEmpty, stall > 0 {
            steps = [PrepareStep(phase: 1, done: 100, total: 1000), PrepareStep(phase: 1, done: 600, total: 1000),
                     PrepareStep(phase: 1, done: 1000, total: 1000)]
        }
        let gap = stall > 0 ? UInt64(stall / Double(steps.count) * 1e9) : 20_000_000
        for step in steps {
            send(.prepare(phase: step.phase, done: step.done, total: step.total))
            try? await Task.sleep(nanoseconds: gap)
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "nxportal.fakegame.reader").async {
                self.startWorkers()
                self.readLoop(sock)
                self.lock.lock(); self.ended = true; self.lock.unlock()
                self.workers.wait()
                self.lock.lock(); self.fd = -1; self.lock.unlock()
                close(sock)
                done.resume()
            }
        }
    }

    private func markFinished() { lock.lock(); finished = true; lock.unlock() }

    // MARK: socket

    /// `false` when `stop()` came first.
    private func adopt(_ sock: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopping { return false }
        fd = sock
        return true
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    private var shouldRun: Bool { lock.lock(); defer { lock.unlock() }; return !stopping && !ended }

    private func connectSocket() throws -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw FakeGameError.connect(errno) }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8)
        guard bytes.count <= 103 else { close(s); throw FakeGameError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { let e = errno; close(s); throw FakeGameError.connect(e) }
        return s
    }

    private func send(_ message: TapMessage) {
        writeLock.lock(); defer { writeLock.unlock() }
        writeLocked(message)
    }

    private func writeLocked(_ message: TapMessage) {
        lock.lock(); let s = fd; lock.unlock()
        guard s >= 0 else { return }
        let data = message.encoded()
        var offset = 0
        data.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = write(s, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return }
                offset += n
            }
        }
    }

    /// Returns when the Host closes the socket, on `quit`, on a framing error, or after `stop()`.
    private func readLoop(_ sock: Int32) {
        var framer = TapFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(sock, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            guard let messages = try? framer.push(Data(buffer[0..<n])) else { return }
            for m in messages {
                lock.lock()
                _received.append(m)
                var changed: UInt64?
                switch m {
                case let .pad(player, buttons, _, _, _, _) where player == 0 && buttons != lastButtons:
                    lastButtons = buttons
                    changed = buttons
                case let .config(w, h, f, b):
                    config = Config(maxWidth: Int(w), maxHeight: Int(h), maxFps: Int(f), bitrate: Int(b))
                    configGeneration += 1
                case .keyframe: forceKey = true
                case let .ltrAck(tokens): acknowledged(tokens)
                case .refresh:
                    // While a key frame or a repair frame is due or in the encoder, that one repairs this loss too.
                    if ltr.fixWait == 0, ltr.refreshIn == nil { ltr.refreshIn = repairDelay } else { _refreshesCoalesced += 1 }
                case let .pause(on): paused = on
                default: break
                }
                let notify = _onButtons
                lock.unlock()
                if let changed { notify?(changed) }
                if case .quit = m, !ignoresQuit { return }
            }
        }
    }

    /// Under `lock`: kept only when of this session's epoch, issued since its last key frame and not already pending.
    private func acknowledged(_ tokens: [Int32]) {
        for wire in tokens where ltr.on {
            let t = wire & 0xFF_FFFF
            guard wire >= 0, wire >> 24 == ltr.epoch, ltr.issued.contains(t), !ltr.pending.contains(t) else { continue }
            if ltr.pending.count == Ltr.pendingMax { ltr.pending.removeFirst() }
            ltr.pending.append(t)
        }
    }

    // MARK: workers

    private func startWorkers() {
        for body in [videoLoop, audioLoop] {
            workers.enter()
            Thread.detachNewThread { body(); self.workers.leave() }
        }
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Absolute-deadline pacing: `true` when a step is due (the deadline then advances by `interval`).
    private static func due(_ deadline: inout UInt64, interval: UInt64) -> Bool {
        let t = now()
        if deadline == 0 || t > deadline + 1_000_000_000 { deadline = t }
        if t < deadline { usleep(UInt32(min((deadline - t) / 1000, 2000))); return false }
        deadline += interval
        return true
    }

    private struct Snapshot { var config: Config?; var generation: Int; var paused: Bool }
    private func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(config: config, generation: configGeneration, paused: paused)
    }

    private func videoLoop() {
        var encoder: FakeEncoder?
        var generation = -1
        var deadline: UInt64 = 0
        var generated = 0
        var needKey = true
        var effFps = fps
        var size = (0, 0)
        while shouldRun {
            let snap = snapshot()
            guard let cfg = snap.config, !snap.paused else { deadline = 0; usleep(2000); continue }
            if encoder == nil || snap.generation != generation {
                let (w, h) = Self.fit(width, height, cfg.maxWidth, cfg.maxHeight)
                effFps = max(1, cfg.maxFps == 0 ? fps : min(fps, cfg.maxFps))
                generation = snap.generation
                // Like the tap: the encoder is made again only on a size change.
                if encoder == nil || (w, h) != size {
                    encoder?.finish()
                    encoder = FakeEncoder(width: w, height: h, fps: effFps, bitrate: cfg.bitrate, ltr: wantLTR) { [self] out in
                        encoded(out, width: w, height: h)
                    }
                    guard let e = encoder else { stop(exitCode: 70); break }
                    // The old session's tokens mean nothing to this one.
                    lock.lock()
                    ltr = Ltr(on: e.ltr, epoch: (ltr.epoch + 1) & 127)
                    lock.unlock()
                    size = (w, h)
                    needKey = true
                    deadline = 0
                }
            }
            guard Self.due(&deadline, interval: UInt64(1_000_000_000 / effFps)) else { continue }
            let captureNs = Self.now()
            let request = nextRequest(key: needKey)
            let colors: [UInt32] = [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF]
            encoder?.encode(color: solid ?? colors[(generated / effFps) % 3], request: request, captureNs: captureNs)
            needKey = false
            generated += 1
        }
        encoder?.finish()
    }

    /// The tap's choice for the next frame (`stream_video_submit`): the acknowledgements pending go with it; a refresh is
    /// a repair frame when the encoder holds an acknowledgement since the last key frame (or this frame carries one),
    /// else a key frame.
    private func nextRequest(key needKey: Bool) -> FakeEncoder.Request {
        lock.lock(); defer { lock.unlock() }
        var r = FakeEncoder.Request(key: needKey || forceKey)
        forceKey = false
        if let n = ltr.refreshIn {
            if n == 0 { r.refresh = true; ltr.refreshIn = nil } else { ltr.refreshIn = n - 1 }
        }
        if !r.key { r.acks = ltr.pending }
        ltr.pending = []
        r.ltrRefresh = r.refresh && !r.key && ltr.on && (ltr.acked || !r.acks.isEmpty)
        if r.refresh && !r.ltrRefresh { r.key = true }
        if r.key { ltr.issued = []; ltr.acked = false; ltr.keyWait += 1 }
        if r.key || r.refresh { ltr.fixWait += 1 }
        return r
    }

    /// The tap's `enc_out`: the state follows what the encoder made, then the frame goes out with its mark and token.
    private func encoded(_ out: FakeEncoder.Output, width: Int, height: Int) {
        let r = out.request, ok = out.status == noErr && out.data != nil
        lock.lock()
        if out.status != noErr || (r.key && !ok) { forceKey = true }  // a lost key frame is asked for again
        if out.status == noErr, r.refresh, !ok, ltr.refreshIn == nil { ltr.refreshIn = 0 }  // and a lost refresh
        if r.key { ltr.keyWait -= 1 }
        if r.key || r.refresh { ltr.fixWait -= 1 }
        if out.status == noErr, !ok {  // dropped: the encoder may not have taken its acknowledgements
            for t in r.acks.reversed() where ltr.issued.contains(t) && !ltr.pending.contains(t) && ltr.pending.count < Ltr.pendingMax {
                ltr.pending.insert(t, at: 0)
            }
        }
        var wire: Int32 = -1
        if ok {
            if out.key { ltr.issued = []; ltr.pending = []; ltr.acked = false }  // a key frame ends every reference before it
            else if !r.acks.isEmpty, ltr.keyWait == 0 { ltr.acked = true }
            if out.token >= 0, ltr.keyWait == 0 {
                if ltr.issued.count == Ltr.issuedMax { ltr.issued.removeFirst() }
                ltr.issued.append(out.token)
            }
            if out.token >= 0, out.token <= 0xFF_FFFF { wire = ltr.epoch << 24 | out.token }
        }
        // The guard: a refresh answered with a key frame although the tap asked for a repair frame.
        if ok, r.refresh, out.key, !r.key { _repairsAnsweredWithKey += 1; forceKey = true }
        lock.unlock()
        guard ok, let data = out.data else { return }
        let mark: FrameMark = out.key ? .key : r.ltrRefresh ? .repair : .none
        deliver(captureNs: out.captureNs, mark: mark, token: wire, data: data, width: width, height: height)
    }

    /// Fit inside the cap, aspect kept, even, never scaled up.
    static func fit(_ w: Int, _ h: Int, _ maxW: Int, _ maxH: Int) -> (Int, Int) {
        let scale = min(1.0, Double(maxW) / Double(w), Double(maxH) / Double(h))
        return (max(2, Int(Double(w) * scale) & ~1), max(2, Int(Double(h) * scale) & ~1))
    }

    /// `data` plus, when padded, one filler-data NAL unit (type 38: length prefix, header 0x4C 0x01, 0xFF bytes, trailing 0x80)
    /// so the frame is `bitrate / 8 / fps` bytes (a key frame 4 times that), as the config stands now.
    private func pad(_ data: Data, key: Bool) -> Data {
        guard padded else { return data }
        let now = Self.now()
        lock.lock(); let cfg = config; let start = loadStartNs ?? now; if loadStartNs == nil { loadStartNs = now }; lock.unlock()
        guard let cfg else { return data }
        let effFps = max(1, cfg.maxFps == 0 ? fps : min(fps, cfg.maxFps))
        let elapsed = Double(now - start) / 1e9
        var bitrate = cfg.bitrate
        switch load {
        case .bitrate: break
        case let .quietUntil(seconds): if elapsed < seconds { bitrate = 100_000 }
        case .halfEveryOtherSecond: if Int(elapsed) % 2 == 0 { bitrate /= 2 }
        }
        let target = bitrate / 8 / effFps * (key ? 4 : 1)
        let room = target - data.count - 7
        guard room >= 0 else { return data }
        var out = data
        out.reserveCapacity(target)
        out.append(Self.fillerNAL(room: room))
        return out
    }

    /// One filler-data NAL unit (type 38) taking `room + 7` bytes: length prefix, header 0x4C 0x01, `room` 0xFF bytes, 0x80.
    static func fillerNAL(room: Int) -> Data {
        var d = Data(capacity: room + 7)
        d.append(contentsOf: withUnsafeBytes(of: UInt32(room + 3).bigEndian, Array.init))
        d.append(contentsOf: [0x4C, 0x01])
        d.append(Data(repeating: 0xFF, count: room))
        d.append(0x80)
        return d
    }

    private func deliver(captureNs: UInt64, mark: FrameMark, token: Int32, data original: Data, width: Int, height: Int) {
        let data = pad(original, key: mark == .key)
        writeLock.lock(); defer { writeLock.unlock() }
        lock.lock()
        let frame = nextFrame
        nextFrame += 1
        _sentVideo[frame] = data
        _sentFrames[frame] = SentFrame(mark: mark, token: token, bytes: data.count)
        if frame >= 600 { _sentVideo[frame - 600] = nil; _sentFrames[frame - 600] = nil }
        lock.unlock()
        writeLocked(.video(frame: frame, captureNs: captureNs, width: UInt16(width), height: UInt16(height),
                           mark: mark, token: token, data: data))
    }

    private func audioLoop() {
        var deadline: UInt64 = 0
        var sample = 0
        while shouldRun {
            let snap = snapshot()
            guard snap.config != nil else { deadline = 0; usleep(2000); continue }  // sound goes on while paused, as in the tap
            guard Self.due(&deadline, interval: 5_000_000) else { continue }
            let captureNs = Self.now()
            var pcm = Data(capacity: 960)
            for _ in 0..<240 {
                let v = Int16(0.3 * 32767 * sin(2 * Double.pi * 440 * Double(sample % 48_000) / 48_000))
                sample += 1
                for _ in 0..<2 { pcm.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
            }
            send(.audio(captureNs: captureNs, channels: 2, pcm: pcm))
        }
    }
}

/// Launches a `FakeGame` in-process.
public final class FakeLauncher: GameLaunching, @unchecked Sendable {
    private let lock = NSLock()  // guards _game
    private var _game: FakeGame?
    private let connectDelay: TimeInterval
    private var _onButtons: (@Sendable (UInt64) -> Void)?
    private let fps: Int
    private let padded: Bool
    private let load: FakeGame.Load
    private let repairDelay: Int
    private let longTermReferences: Bool
    private let preparePhases: [UInt32]
    private let prepareSteps: [FakeGame.PrepareStep]
    private let stall: TimeInterval
    private let solidColor: UInt32?
    private let ignoresQuit: Bool
    private let width: Int
    private let height: Int

    /// `connectDelay`: seconds between launch and the game connecting to the socket; `width` and `height`: the picture size
    /// the fake game renders (the encoder's size is that, or the device's cap when smaller); the rest -> `FakeGame.init`.
    public init(connectDelay: TimeInterval = 0, fps: Int = 60, paddedToBitrate: Bool = false, load: FakeGame.Load = .bitrate,
                repairDelay: Int = 1, longTermReferences: Bool = true, preparePhases: [UInt32] = [], ignoresQuit: Bool = false,
                prepareSteps: [FakeGame.PrepareStep] = [], stall: TimeInterval = 0, solidColor: UInt32? = nil,
                width: Int = 1280, height: Int = 720) {
        self.width = width; self.height = height
        self.prepareSteps = prepareSteps; self.stall = stall; self.solidColor = solidColor
        self.ignoresQuit = ignoresQuit
        self.connectDelay = connectDelay; self.fps = fps; self.padded = paddedToBitrate; self.load = load
        self.repairDelay = repairDelay; self.longTermReferences = longTermReferences; self.preparePhases = preparePhases
    }

    /// Handed to every game this launcher makes -> `FakeGame.onButtons`.
    public var onButtons: (@Sendable (UInt64) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onButtons }
        set { lock.lock(); _onButtons = newValue; lock.unlock() }
    }

    /// The most recent one.
    public var game: FakeGame? { lock.lock(); defer { lock.unlock() }; return _game }

    private func remember(_ g: FakeGame) { lock.lock(); _game = g; lock.unlock() }

    /// The environment each launch was given, oldest first.
    public var environments: [[String: String]] { lock.withLock { _environments } }
    private var _environments: [[String: String]] = []  // guarded by lock

    public func launch(titleID: String, socketPath: String, environment: [String: String]) async throws -> any RunningGame {
        lock.withLock { _environments.append(environment) }
        return try await launch(titleID: titleID, socketPath: socketPath)
    }

    public func launch(titleID: String, socketPath: String) async throws -> any RunningGame {
        let g = FakeGame(socketPath: socketPath, titleID: titleID, name: "Fake Game", width: width, height: height, fps: fps, paddedToBitrate: padded, load: load,
                         repairDelay: repairDelay, longTermReferences: longTermReferences, preparePhases: preparePhases,
                         prepareSteps: prepareSteps, stall: stall, solidColor: solidColor)
        g.onButtons = onButtons
        g.ignoresQuit = ignoresQuit
        remember(g)
        let delay = connectDelay
        let task = Task<Int32, Never> {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            do { try await g.run(); return g.exitCode } catch { return 1 }
        }
        return FakeRunningGame(game: g, task: task)
    }
}

private struct FakeRunningGame: RunningGame {
    let game: FakeGame
    let task: Task<Int32, Never>
    func terminate() async { game.stop(exitCode: 15) }
    func waitForExit() async -> Int32 { await task.value }
    /// The fake runs inside the test process: its process id is the one to read.
    var pid: Int32? { ProcessInfo.processInfo.processIdentifier }
}
#endif
