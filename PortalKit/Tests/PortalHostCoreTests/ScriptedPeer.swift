#if os(macOS)
import CryptoKit
import Foundation
import PortalKit

enum PeerError: Error { case connect(Int32), socket(Int32), noReply(String), refused(Refusal), pairing(PairResult) }

/// Test-only client over loopback: POSIX TCP + UDP, PortalKit's pairing, sealers and `FrameAssembler`.
/// Waits poll what the reader threads collected (as `EventCollector` does).
final class ScriptedPeer: @unchecked Sendable {
    struct ReceivedFrame { var frame: AssembledFrame; var socket: Int }

    let identity: Identity
    let name: String

    private let lock = NSLock()  // guards every var below
    private var tcp: Int32 = -1
    private var tcpClosed = false
    private var inbox: [ControlMessage] = []
    private var cursor = 0
    private var pendingEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var ctlSealer: StreamSealer?
    private var ctlOpener: StreamOpener?
    private var mediaSealer: DatagramSealer?
    private var mediaOpener: DatagramOpener?
    private var udpPort: UInt16 = 0
    private var sockets: [Int32] = []
    private var current = 0
    private var assembler = FrameAssembler()
    private var frames: [ReceivedFrame] = []
    private var fragmentLog: [VideoFragment] = []
    private var audioPCM: [Data] = []
    private var pongs = 0
    private var hostStatsLog: [HostStats] = []
    private var loadLog: [(at: Date, load: HostLoad)] = []
    private var biggest = 0
    private var perSocket: [Int: Int] = [:]
    private var sessionID: UInt32 = 0
    private var silent = false
    private var autoKey = true
    private var lastAutoKey = Date.distantPast
    /// A refresh came and no key frame since: the key request is repeated every 100 ms, as the session does.
    private var awaitingKey = false
    private var stopping = false
    /// False: the control connection is not read (the Host's sends back up).
    private var reading = true
    private var inputSeq: UInt32 = 0
    private(set) var hostKey: Data?
    private let threads = DispatchGroup()
    private var pinger: Task<Void, Never>?

    /// How the Host's log names this device.
    var tag: String { Identity.tag(publicKey: identity.publicKey) }

    init(identity: Identity = Identity(), name: String) {
        self.identity = identity
        self.name = name
    }

    deinit { close() }

    // MARK: state

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    var isClosed: Bool { locked { tcpClosed } }
    var messages: [ControlMessage] { locked { inbox } }
    var received: [ReceivedFrame] { locked { frames } }
    /// Every video fragment that opened, in arrival order (resends included).
    var fragments: [VideoFragment] { locked { fragmentLog } }
    var audio: [Data] { locked { audioPCM } }
    var pongCount: Int { locked { pongs } }
    var hostStats: [HostStats] { locked { hostStatsLog } }
    /// Every `load` datagram that opened, with its arrival time.
    var loads: [(at: Date, load: HostLoad)] { locked { loadLog } }
    var largestDatagram: Int { locked { biggest } }
    var sessionKnown: Bool { locked { mediaSealer != nil } }
    /// Silent: nothing is sent at all (pings, key requests, control).
    func setSilent(_ on: Bool) { locked { silent = on } }
    func setAutoKeyRequest(_ on: Bool) { locked { autoKey = on } }
    func trust(hostKey key: Data) { locked { hostKey = key } }
    func setReading(_ on: Bool) { locked { reading = on } }

    // MARK: control

    func connect(port: UInt16) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw PeerError.socket(errno) }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.loopback(port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw PeerError.connect(e) }
        locked { tcp = s }
        threads.enter()
        Thread.detachNewThread { self.controlLoop(s); self.threads.leave() }
    }

    /// Sealed once `welcome` has arrived, in the clear before.
    func send(_ message: ControlMessage) {
        lock.lock(); defer { lock.unlock() }
        guard !silent, tcp >= 0, let json = try? message.encoded() else { return }
        let payload: Data
        if ctlSealer != nil { guard let p = try? ctlSealer!.seal(json) else { return }; payload = p } else { payload = json }
        Self.writeAll(tcp, ControlFramer.frame(payload))
    }

    /// Writes a raw frame, unsealed, whatever the phase.
    func sendClearFrame(_ message: ControlMessage) {
        lock.lock(); defer { lock.unlock() }
        guard tcp >= 0, let json = try? message.encoded() else { return }
        Self.writeAll(tcp, ControlFramer.frame(json))
    }

    /// The first message after the cursor that matches; moves the cursor past it.
    func next(timeout: TimeInterval = 5, _ match: @escaping (ControlMessage) -> Bool = { _ in true }) async -> ControlMessage? {
        let end = Date().addingTimeInterval(timeout)
        while true {
            let hit: ControlMessage? = locked {
                guard let i = inbox[cursor...].firstIndex(where: match) else { return nil }
                cursor = i + 1
                return inbox[i]
            }
            if let hit { return hit }
            if Date() >= end { return nil }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func waitClosed(timeout: TimeInterval = 5) async -> Bool {
        await wait(timeout: timeout) { self.isClosed }
    }

    func pair(code: String) async throws -> PairResult {
        var client = PairingClient(identity: identity, name: name)
        send(.pairStart(client.start()))
        let reply = await next { if case .pairChallenge = $0 { true } else { $0.isPairResult } }
        if case let .pairResult(r)? = reply { return r }
        guard case let .pairChallenge(challenge)? = reply else { throw PeerError.noReply("pairChallenge") }
        send(.pairProof(try client.proof(for: challenge, code: code)))
        guard case let .pairResult(result)? = await next({ $0.isPairResult }) else { throw PeerError.noReply("pairResult") }
        if case .ok = result { trust(hostKey: try client.finish(result).key) }
        return result
    }

    /// Sends `hello`; returns the `welcome` or `refuse` that answers it.
    func hello(version: UInt16 = ProtocolVersion.network, maxWidth: UInt16 = 1920, maxHeight: UInt16 = 1080,
               maxFps: UInt8 = 60, bitrate: UInt32? = nil, resume: Bool? = nil, startBps: UInt32? = nil,
               helloName: String? = nil, claimedKey: Data? = nil) async -> ControlMessage? {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        locked { pendingEphemeral = eph }
        send(.hello(Hello(version: version, clientKey: claimedKey ?? identity.publicKey, ephemeral: eph.publicKey.rawRepresentation,
                          kind: .tool, maxWidth: maxWidth, maxHeight: maxHeight, maxFps: maxFps, bitrate: bitrate,
                          resume: resume, startBps: startBps, name: helloName)))
        return await next {
            switch $0 { case .welcome, .refuse: true; default: false }
        }
    }

    /// Sealed `ready`, then the first UDP socket and a ping at once.
    func ready() throws {
        send(.ready)
        _ = try addSocket()
        sendDatagram(.ping(clientNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
    }

    /// connect + hello + ready; pings every 200 ms after. `resume: false` opens a library session.
    func open(port: UInt16, maxWidth: UInt16 = 1920, maxHeight: UInt16 = 1080, maxFps: UInt8 = 60,
              bitrate: UInt32? = nil, resume: Bool? = nil, startBps: UInt32? = nil,
              helloName: String? = nil) async throws {
        if locked({ tcp }) < 0 { try connect(port: port) }
        let reply = await hello(maxWidth: maxWidth, maxHeight: maxHeight, maxFps: maxFps, bitrate: bitrate, resume: resume,
                                startBps: startBps, helloName: helloName)
        if case let .refuse(r)? = reply { throw PeerError.refused(r) }
        guard case .welcome? = reply else { throw PeerError.noReply("welcome") }
        try ready()
        startPings()
    }

    func startPings() {
        pinger?.cancel()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.sendDatagram(.ping(clientNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
            }
        }
    }

    /// TCP closed from our side.
    func closeControl() {
        locked { if tcp >= 0 { shutdown(tcp, SHUT_RDWR) } }
    }

    /// TCP aborted from our side: the Host's receive fails (reset) instead of seeing a clean close.
    func resetControl() async {
        locked { if tcp >= 0 { shutdown(tcp, SHUT_RD) } }  // wakes the reader; sends nothing
        _ = await wait(timeout: 2) { self.locked { self.tcpClosed } }
        locked {
            guard tcp >= 0 else { return }
            var abort = linger(l_onoff: 1, l_linger: 0)
            setsockopt(tcp, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
            Darwin.close(tcp)
            tcp = -1
        }
    }

    func close() {
        pinger?.cancel()
        let fds: [Int32] = locked {
            stopping = true
            if tcp >= 0 { shutdown(tcp, SHUT_RDWR) }
            return sockets
        }
        threads.wait()
        locked {
            if tcp >= 0 { Darwin.close(tcp); tcp = -1 }
            for s in fds { Darwin.close(s) }
            sockets = []
        }
    }

    private func controlLoop(_ s: Int32) {
        var framer = ControlFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        loop: while true {
            while !locked({ reading || stopping }) { usleep(5_000) }
            let n = read(s, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            guard let payloads = try? framer.push(Data(buffer[0..<n])) else { break }
            for p in payloads where !accept(p) { break loop }
        }
        locked { tcpClosed = true }
    }

    /// Opens (once keyed) and decodes one control payload; a `welcome` installs the session keys.
    private func accept(_ payload: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var json = payload
        if ctlOpener != nil { guard let p = try? ctlOpener!.open(payload) else { return false }; json = p }
        guard let m = try? ControlMessage(decoding: json) else { return false }
        inbox.append(m)
        if case let .welcome(w) = m, let eph = pendingEphemeral, let hostKey,
           let keys = try? SessionKeys.derive(role: .client, identity: identity, ephemeral: eph,
                                              peerKey: hostKey, peerEphemeral: w.ephemeral) {
            ctlSealer = StreamSealer(key: keys.clientToHostControl)
            ctlOpener = StreamOpener(key: keys.hostToClientControl)
            mediaSealer = DatagramSealer(key: keys.clientToHostMedia, sessionID: w.sessionID)
            mediaOpener = DatagramOpener(key: keys.hostToClientMedia, sessionID: w.sessionID)
            udpPort = w.udpPort
            sessionID = w.sessionID
            pendingEphemeral = nil
        }
        return true
    }

    // MARK: media

    /// A new local UDP socket; later datagrams leave from it by default. Returns its index.
    @discardableResult
    func addSocket(makeCurrent: Bool = true) throws -> Int {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw PeerError.socket(errno) }
        var size: Int32 = 4 << 20
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let index: Int = locked {
            sockets.append(s)
            if makeCurrent { current = sockets.count - 1 }
            return sockets.count - 1
        }
        threads.enter()
        Thread.detachNewThread { self.mediaLoop(s, index: index); self.threads.leave() }
        return index
    }

    func sendDatagram(_ d: Datagram, socket index: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !silent, mediaSealer != nil, let data = try? mediaSealer!.seal(type: d.type, body: d.body()) else { return }
        rawSendLocked(data, index ?? current)
    }

    func sendRaw(_ data: Data, socket index: Int) { locked { rawSendLocked(data, index) } }

    func datagrams(socket index: Int) -> Int { locked { perSocket[index] ?? 0 } }

    /// The right header (session, a far-ahead counter) with a body that was never sealed.
    func forgedDatagram() -> Data {
        let sid = locked { sessionID }
        var d = Data([0x24, 0, 0, 0])
        withUnsafeBytes(of: sid.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(1 << 40).littleEndian) { d.append(contentsOf: $0) }
        d.append(Datagram.ping(clientNs: 1).body())
        d.append(Data(count: 16))
        return d
    }

    /// Input for player 0 with the next sequence number (or the one given).
    func sendInput(buttons: UInt64, seq: UInt32? = nil) {
        let s: UInt32 = locked { inputSeq = seq ?? inputSeq + 1; return inputSeq }
        sendDatagram(.input(InputState(seq: s, player: 0, buttons: buttons, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil)))
    }

    private func rawSendLocked(_ data: Data, _ index: Int) {
        guard index < sockets.count, udpPort != 0 else { return }
        var addr = Self.loopback(udpPort)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sockets[index], raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func mediaLoop(_ s: Int32, index: Int) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !locked({ stopping }) {
            let n = recv(s, &buffer, buffer.count, 0)
            if n <= 0 { continue }
            handleDatagram(Data(buffer[0..<n]), socket: index)
        }
    }

    private func handleDatagram(_ data: Data, socket index: Int) {
        lock.lock(); defer { lock.unlock() }
        biggest = max(biggest, data.count)
        perSocket[index, default: 0] += 1
        guard mediaOpener != nil, let (type, body) = try? mediaOpener!.open(data),
              let d = try? Datagram(type: type, body: body) else { return }
        switch d {
        case let .video(f):
            fragmentLog.append(f)
            for event in assembler.push(f, nowNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
            switch event {
            case let .frame(frame):
                frames.append(ReceivedFrame(frame: frame, socket: index))
                if frame.key { awaitingKey = false }
            case .refresh: awaitingKey = true
            case .nack: break  // the raw peer does not ask; tests send their own nacks
            }
            }
            if awaitingKey, autoKey, Date().timeIntervalSince(lastAutoKey) >= 0.1 {
                lastAutoKey = Date()
                let last = frames.last?.frame.frame ?? 0
                if !silent, let k = try? mediaSealer!.seal(type: 0x23, body: Datagram.keyRequest(lastGoodFrame: last).body()) {
                    rawSendLocked(k, current)
                }
            }
        case let .audio(_, _, pcm): audioPCM.append(pcm)
        case .pong: pongs += 1
        case let .hostStats(h): hostStatsLog.append(h)
        case let .load(l): loadLog.append((Date(), l))
        default: break
        }
    }

    // MARK: helpers

    func wait(timeout: TimeInterval = 5, until cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return }
                off += n
            }
        }
    }
}

extension ControlMessage {
    var isPairResult: Bool { if case .pairResult = self { return true }; return false }
    var gameState: GameState? { if case let .gameState(s) = self { return s }; return nil }
}
#endif
