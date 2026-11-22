import Foundation

/// `key` and `repair` are the tap's mark of the frame (never both), carried in every fragment as one flags byte.
public struct VideoFragment: Equatable, Sendable {
    public var frame: UInt32, index: UInt16, count: UInt16, key: Bool, captureNs: UInt64, width: UInt16, height: UInt16, payload: Data
    public var repair: Bool
    public init(frame: UInt32, index: UInt16, count: UInt16, key: Bool, repair: Bool = false, captureNs: UInt64, width: UInt16,
                height: UInt16, payload: Data) {
        precondition(!(key && repair), "a frame is a key frame or a repair frame, never both")
        self.frame = frame; self.index = index; self.count = count; self.key = key; self.repair = repair
        self.captureNs = captureNs; self.width = width; self.height = height; self.payload = payload
    }
}

/// What the Host counted since the session began (`Datagram.hostStats`): video frames received from the game, frames
/// fully handed to the network, frames the sender dropped unsent, resend datagrams sent, the video rate it set, and the
/// worst time (us) a sending slice left late against its schedule in the last second.
public struct HostStats: Equatable, Sendable {
    public var framesFromGame: UInt32, framesSent: UInt32, framesDropped: UInt32, resent: UInt32, rateBps: UInt32
    public var sendLateMaxUs: UInt32
    public init(framesFromGame: UInt32, framesSent: UInt32, framesDropped: UInt32, resent: UInt32, rateBps: UInt32,
                sendLateMaxUs: UInt32 = 0) {
        self.framesFromGame = framesFromGame; self.framesSent = framesSent; self.framesDropped = framesDropped
        self.resent = resent; self.rateBps = rateBps; self.sendLateMaxUs = sendLateMaxUs
    }
}

/// The Mac's load, once a second while a device's numbers panel is at "full" (`Datagram.load`): numbers only, no names or
/// paths -> .claude/portalkit.md § wire-network. Percentages are tenths of a percent (0...1000); `gpu` is meaningful only
/// with `gpuPresent`; the game's fields only with `gameAlive`; frame times in tenths of a millisecond, fps in tenths.
public struct HostLoad: Equatable, Sendable {
    public var gpuPresent: Bool, gameAlive: Bool
    public var thermal: UInt8, pressure: UInt8
    public var cpuTotal: UInt16, cpuPerf: UInt16, cpuEff: UInt16, gpu: UInt16
    public var memUsedMiB: UInt32, memTotalMiB: UInt32, gameCpuCentiCores: UInt32, gameMemMiB: UInt32
    public var gameFpsDeci: UInt16, frameMeanDeciMs: UInt16, frameP95DeciMs: UInt16, frameMaxDeciMs: UInt16

    public init(gpuPresent: Bool = false, gameAlive: Bool = false, thermal: UInt8 = 0, pressure: UInt8 = 0,
                cpuTotal: UInt16 = 0, cpuPerf: UInt16 = 0, cpuEff: UInt16 = 0, gpu: UInt16 = 0,
                memUsedMiB: UInt32 = 0, memTotalMiB: UInt32 = 0, gameCpuCentiCores: UInt32 = 0, gameMemMiB: UInt32 = 0,
                gameFpsDeci: UInt16 = 0, frameMeanDeciMs: UInt16 = 0, frameP95DeciMs: UInt16 = 0, frameMaxDeciMs: UInt16 = 0) {
        self.gpuPresent = gpuPresent; self.gameAlive = gameAlive; self.thermal = thermal; self.pressure = pressure
        self.cpuTotal = cpuTotal; self.cpuPerf = cpuPerf; self.cpuEff = cpuEff; self.gpu = gpu
        self.memUsedMiB = memUsedMiB; self.memTotalMiB = memTotalMiB
        self.gameCpuCentiCores = gameCpuCentiCores; self.gameMemMiB = gameMemMiB
        self.gameFpsDeci = gameFpsDeci; self.frameMeanDeciMs = frameMeanDeciMs
        self.frameP95DeciMs = frameP95DeciMs; self.frameMaxDeciMs = frameMaxDeciMs
    }

    /// The `gpu` field's value when the Mac gives none.
    public static let gpuNotAvailable: UInt16 = 0xFFFF
}

public struct MotionSample: Equatable, Sendable {
    public var frame: MotionFrame, acc: SIMD3<Float>, rot: SIMD3<Float>
    public init(frame: MotionFrame, acc: SIMD3<Float>, rot: SIMD3<Float>) { self.frame = frame; self.acc = acc; self.rot = rot }
}

public struct InputState: Equatable, Sendable {
    public var seq: UInt32, player: UInt8, buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32, motion: MotionSample?
    public init(seq: UInt32, player: UInt8, buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32, motion: MotionSample?) {
        self.seq = seq; self.player = player; self.buttons = buttons
        self.lx = lx; self.ly = ly; self.rx = rx; self.ry = ry; self.motion = motion
    }
}

/// UDP media bodies (after the 16-byte clear header) -> .claude/portalkit.md § wire-network
public enum Datagram: Equatable, Sendable {
    case video(VideoFragment)
    case audio(seq: UInt32, captureNs: UInt64, pcm: Data)
    case input(InputState)
    case keyRequest(lastGoodFrame: UInt32)
    case ping(clientNs: UInt64)
    case pong(clientNs: UInt64, hostNs: UInt64)
    /// Client to Host: resend these fragments of `frame` (at most `maxNackIndices`; none = every fragment of it).
    case nack(frame: UInt32, indices: [UInt16])
    /// Client to Host: the video rate wished for now (bit/s), below the hello's ceiling -> .claude/portalkit.md § wire-network
    case rate(bitsPerSecond: UInt32)
    /// Host to client, once a second: the Host's own counts since the session began -> .claude/portalkit.md § wire-network
    case hostStats(HostStats)
    /// Client to Host: the newest frame the device decoded (the Host acknowledges its token to the game).
    case ack(frame: UInt32)
    /// Client to Host: a frame was given up; a restart point is wanted (the game sends a repair frame where it can).
    /// `keyRequest` keeps its meaning: a real key frame -> .claude/portalkit.md § wire-network
    case repair(lastGoodFrame: UInt32)
    /// Host to client, once a second while the device's numbers panel is at "full"; never retransmitted, a lost one is
    /// replaced by the next -> .claude/portalkit.md § wire-network
    case load(HostLoad)

    public static let maxNackIndices = 64

    public var type: UInt8 {
        switch self {
        case .video: 0x20
        case .audio: 0x21
        case .input: 0x22
        case .keyRequest: 0x23
        case .ping: 0x24
        case .pong: 0x25
        case .nack: 0x26
        case .rate: 0x27
        case .ack: 0x28
        case .hostStats: 0x29
        case .repair: 0x2A
        case .load: 0x2B
        }
    }

    public func body() -> Data {
        var w = ByteWriter()
        switch self {
        case let .video(f):
            w.u32(f.frame); w.u16(f.index); w.u16(f.count); w.u8((f.key ? 1 : 0) | (f.repair ? 2 : 0)); w.u64(f.captureNs)
            w.u16(f.width); w.u16(f.height); w.bytes(f.payload)
        case let .audio(seq, captureNs, pcm):
            w.u32(seq); w.u64(captureNs); w.bytes(pcm)
        case let .input(s):
            w.u32(s.seq); w.u8(s.player); w.u64(s.buttons); w.i32(s.lx); w.i32(s.ly); w.i32(s.rx); w.i32(s.ry)
            if let m = s.motion { w.bool(true); w.u8(m.frame.rawValue); w.vec3(m.acc); w.vec3(m.rot) } else { w.bool(false) }
        case let .keyRequest(last):
            w.u32(last)
        case let .ping(clientNs):
            w.u64(clientNs)
        case let .pong(clientNs, hostNs):
            w.u64(clientNs); w.u64(hostNs)
        case let .nack(frame, indices):
            precondition(indices.count <= Self.maxNackIndices, "nack: more than 64 indices")
            w.u32(frame); w.u8(UInt8(indices.count))
            for i in indices { w.u16(i) }
        case let .rate(bps):
            w.u32(bps)
        case let .hostStats(h):
            w.u32(h.framesFromGame); w.u32(h.framesSent); w.u32(h.framesDropped); w.u32(h.resent); w.u32(h.rateBps); w.u32(h.sendLateMaxUs)
        case let .ack(frame):
            w.u32(frame)
        case let .repair(last):
            w.u32(last)
        case let .load(h):
            w.u8((h.gpuPresent ? 1 : 0) | (h.gameAlive ? 2 : 0)); w.u8(h.thermal); w.u8(h.pressure)
            w.u16(h.cpuTotal); w.u16(h.cpuPerf); w.u16(h.cpuEff); w.u16(h.gpuPresent ? h.gpu : HostLoad.gpuNotAvailable)
            w.u32(h.memUsedMiB); w.u32(h.memTotalMiB); w.u32(h.gameCpuCentiCores); w.u32(h.gameMemMiB)
            w.u16(h.gameFpsDeci); w.u16(h.frameMeanDeciMs); w.u16(h.frameP95DeciMs); w.u16(h.frameMaxDeciMs)
        }
        return w.data
    }

    public init(type: UInt8, body: Data) throws {
        var r = ByteReader(body)
        switch type {
        case 0x20:
            let frame = try r.u32(), index = try r.u16(), count = try r.u16(), flags = try r.u8()
            guard flags <= 2 else { throw WireError.malformed }  // bit 0 key, bit 1 repair, never both
            let f = VideoFragment(frame: frame, index: index, count: count, key: flags == 1, repair: flags == 2,
                                  captureNs: try r.u64(), width: try r.u16(), height: try r.u16(), payload: r.rest())
            guard f.count != 0, f.index < f.count else { throw WireError.malformed }
            self = .video(f)
        case 0x21:
            self = .audio(seq: try r.u32(), captureNs: try r.u64(), pcm: r.rest())
        case 0x22:
            var s = InputState(seq: try r.u32(), player: try r.u8(), buttons: try r.u64(),
                               lx: try r.i32(), ly: try r.i32(), rx: try r.i32(), ry: try r.i32(), motion: nil)
            if try r.bool() {
                guard let frame = MotionFrame(rawValue: try r.u8()) else { throw WireError.malformed }
                s.motion = MotionSample(frame: frame, acc: try r.vec3(), rot: try r.vec3())
            }
            self = .input(s)
        case 0x23:
            self = .keyRequest(lastGoodFrame: try r.u32())
        case 0x24:
            self = .ping(clientNs: try r.u64())
        case 0x25:
            self = .pong(clientNs: try r.u64(), hostNs: try r.u64())
        case 0x26:
            let frame = try r.u32(), n = Int(try r.u8())
            guard n <= Self.maxNackIndices else { throw WireError.malformed }
            var indices: [UInt16] = []
            indices.reserveCapacity(n)
            for _ in 0..<n { indices.append(try r.u16()) }
            self = .nack(frame: frame, indices: indices)
        case 0x27:
            self = .rate(bitsPerSecond: try r.u32())
        case 0x28:
            self = .ack(frame: try r.u32())
        case 0x2A:
            self = .repair(lastGoodFrame: try r.u32())
        case 0x29:
            self = .hostStats(HostStats(framesFromGame: try r.u32(), framesSent: try r.u32(), framesDropped: try r.u32(),
                                        resent: try r.u32(), rateBps: try r.u32(), sendLateMaxUs: try r.u32()))
        case 0x2B:
            let flags = try r.u8()
            guard flags <= 3 else { throw WireError.malformed }  // bit 0 GPU present, bit 1 game alive
            var h = HostLoad(gpuPresent: flags & 1 != 0, gameAlive: flags & 2 != 0, thermal: try r.u8(), pressure: try r.u8(),
                             cpuTotal: try r.u16(), cpuPerf: try r.u16(), cpuEff: try r.u16(), gpu: try r.u16())
            if !h.gpuPresent { h.gpu = 0 }
            h.memUsedMiB = try r.u32(); h.memTotalMiB = try r.u32(); h.gameCpuCentiCores = try r.u32(); h.gameMemMiB = try r.u32()
            h.gameFpsDeci = try r.u16(); h.frameMeanDeciMs = try r.u16(); h.frameP95DeciMs = try r.u16(); h.frameMaxDeciMs = try r.u16()
            self = .load(h)
        default:
            throw WireError.unknownType(type)
        }
        try r.finish()
    }
}

/// Bit order of nxnative's DM_BTN_*.
public struct PadButtons: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let a = PadButtons(rawValue: 1 << 0)
    public static let b = PadButtons(rawValue: 1 << 1)
    public static let x = PadButtons(rawValue: 1 << 2)
    public static let y = PadButtons(rawValue: 1 << 3)
    public static let stickL = PadButtons(rawValue: 1 << 4)
    public static let stickR = PadButtons(rawValue: 1 << 5)
    public static let l = PadButtons(rawValue: 1 << 6)
    public static let r = PadButtons(rawValue: 1 << 7)
    public static let zl = PadButtons(rawValue: 1 << 8)
    public static let zr = PadButtons(rawValue: 1 << 9)
    public static let plus = PadButtons(rawValue: 1 << 10)
    public static let minus = PadButtons(rawValue: 1 << 11)
    public static let left = PadButtons(rawValue: 1 << 12)
    public static let up = PadButtons(rawValue: 1 << 13)
    public static let right = PadButtons(rawValue: 1 << 14)
    public static let down = PadButtons(rawValue: 1 << 15)

    private static let names = ["A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "Plus", "Minus", "Left", "Up", "Right", "Down"]

    public init?(name: String) {
        guard let bit = Self.names.firstIndex(of: name) else { return nil }
        self.init(rawValue: 1 << UInt64(bit))
    }
}

public enum Wire {
    public static let maxDatagram = 1200, datagramHeader = 16, sealOverhead = 16, videoHeader = 21
    public static let maxVideoPayload = 1147   // 1200 - 16 - 16 - 21
}
