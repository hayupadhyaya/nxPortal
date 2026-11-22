import Foundation

public enum WireError: Error, Equatable {
    case tooLarge, malformed, unknownType(UInt8)
    /// A per-game options message over the limits of `OptionLimits`: ignored by whoever reads it, the session goes on.
    case refused
}
public enum MotionFrame: UInt8, Sendable { case controller = 0, switchDevice = 1 }
/// The flags byte of a tap `video` (protocol 2): a key frame, a repair frame (predicted from an acknowledged frame
/// after a `refresh`, never a key frame), or neither; 3 and other bits are malformed -> .claude/portalkit.md § wire-tap
public enum FrameMark: UInt8, Sendable { case none = 0, key = 1, repair = 2 }

/// Tap socket, game <-> Host -> .claude/portalkit.md § wire-tap
public enum TapMessage: Equatable, Sendable {
    case hello(version: UInt16, titleID: String, name: String)
    /// `token`: the frame's long-term-reference token, opaque (returned unchanged in `ltrAck`); -1 = none.
    case video(frame: UInt32, captureNs: UInt64, width: UInt16, height: UInt16, mark: FrameMark, token: Int32, data: Data)
    case audio(captureNs: UInt64, channels: UInt8, pcm: Data)
    /// Game to Host before its first frame: a preparation phase's progress (phase 1, 2, ... ; `done == total` ends it).
    case prepare(phase: UInt8, done: UInt32, total: UInt32)
    case config(maxWidth: UInt16, maxHeight: UInt16, maxFps: UInt8, bitrate: UInt32)
    case keyframe
    case pad(player: UInt8, buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32)
    case motion(player: UInt8, frame: MotionFrame, acc: SIMD3<Float>, rot: SIMD3<Float>)
    case players(mask: UInt32)
    case pause(Bool)
    case quit
    case motionClear(player: UInt8)
    /// Host to game: tokens of frames the device decoded (1...`maxLtrAck`).
    case ltrAck([Int32])
    /// Host to game: a frame was lost; the next frame is a repair frame where the encoder can, else a key frame.
    case refresh

    static let titleIDLength = 16
    public static let maxLtrAck = 16

    /// Framed: u32 length of (type + payload), type, payload.
    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .hello(version, titleID, name):
            w.u8(0x01); w.u16(version)
            var id = Data(titleID.utf8.prefix(Self.titleIDLength))
            id.append(Data(count: Self.titleIDLength - id.count))
            w.bytes(id)
            let n = Data(name.utf8.prefix(Int(UInt16.max)))
            w.u16(UInt16(n.count)); w.bytes(n)
        case let .video(frame, captureNs, width, height, mark, token, data):
            w.u8(0x02); w.u32(frame); w.u64(captureNs); w.u16(width); w.u16(height); w.u8(mark.rawValue); w.i32(token)
            w.bytes(data)
        case let .audio(captureNs, channels, pcm):
            w.u8(0x03); w.u64(captureNs); w.u8(channels); w.bytes(pcm)
        case let .prepare(phase, done, total):
            w.u8(0x04); w.u8(phase); w.u32(done); w.u32(total)
        case let .config(maxWidth, maxHeight, maxFps, bitrate):
            w.u8(0x10); w.u16(maxWidth); w.u16(maxHeight); w.u8(maxFps); w.u32(bitrate)
        case .keyframe:
            w.u8(0x11)
        case let .pad(player, buttons, lx, ly, rx, ry):
            w.u8(0x12); w.u8(player); w.u64(buttons); w.i32(lx); w.i32(ly); w.i32(rx); w.i32(ry)
        case let .motion(player, frame, acc, rot):
            w.u8(0x13); w.u8(player); w.u8(frame.rawValue); w.vec3(acc); w.vec3(rot)
        case let .players(mask):
            w.u8(0x14); w.u32(mask)
        case let .pause(on):
            w.u8(0x15); w.bool(on)
        case .quit:
            w.u8(0x16)
        case let .motionClear(player):
            w.u8(0x17); w.u8(player)
        case let .ltrAck(tokens):
            precondition((1...Self.maxLtrAck).contains(tokens.count), "ltrAck: 1...16 tokens")
            w.u8(0x18); w.u8(UInt8(tokens.count))
            for t in tokens { w.i32(t) }
        case .refresh:
            w.u8(0x19)
        }
        return LengthPrefixedBuffer.frame(w.data)
    }

    /// `body` is type byte + payload (the framed content).
    init(body: Data) throws {
        var r = ByteReader(body)
        let type = try r.u8()
        switch type {
        case 0x01:
            let version = try r.u16()
            var id = try r.bytes(Self.titleIDLength)
            while id.last == 0 { id.removeLast() }
            guard id.allSatisfy({ $0 < 0x80 }), let titleID = String(data: id, encoding: .utf8) else { throw WireError.malformed }
            guard let name = String(data: try r.bytes(Int(try r.u16())), encoding: .utf8) else { throw WireError.malformed }
            self = .hello(version: version, titleID: titleID, name: name)
        case 0x02:
            let frame = try r.u32(), captureNs = try r.u64(), width = try r.u16(), height = try r.u16()
            guard let mark = FrameMark(rawValue: try r.u8()) else { throw WireError.malformed }
            self = .video(frame: frame, captureNs: captureNs, width: width, height: height, mark: mark, token: try r.i32(),
                          data: r.rest())
        case 0x03:
            self = .audio(captureNs: try r.u64(), channels: try r.u8(), pcm: r.rest())
        case 0x04:
            self = .prepare(phase: try r.u8(), done: try r.u32(), total: try r.u32())
        case 0x10:
            self = .config(maxWidth: try r.u16(), maxHeight: try r.u16(), maxFps: try r.u8(), bitrate: try r.u32())
        case 0x11:
            self = .keyframe
        case 0x12:
            self = .pad(player: try r.u8(), buttons: try r.u64(), lx: try r.i32(), ly: try r.i32(), rx: try r.i32(), ry: try r.i32())
        case 0x13:
            let player = try r.u8()
            guard let frame = MotionFrame(rawValue: try r.u8()) else { throw WireError.malformed }
            self = .motion(player: player, frame: frame, acc: try r.vec3(), rot: try r.vec3())
        case 0x14:
            self = .players(mask: try r.u32())
        case 0x15:
            self = .pause(try r.bool())
        case 0x16:
            self = .quit
        case 0x17:
            self = .motionClear(player: try r.u8())
        case 0x18:
            let n = Int(try r.u8())
            guard (1...Self.maxLtrAck).contains(n) else { throw WireError.malformed }
            var tokens: [Int32] = []
            tokens.reserveCapacity(n)
            for _ in 0..<n { tokens.append(try r.i32()) }
            self = .ltrAck(tokens)
        case 0x19:
            self = .refresh
        default:
            throw WireError.unknownType(type)
        }
        try r.finish()
    }
}

public struct TapFramer: Sendable {
    private var buffer: LengthPrefixedBuffer

    public init(maxMessage: Int = 8 << 20) { buffer = LengthPrefixedBuffer(maxMessage: maxMessage) }

    /// A message of a type this side does not know is skipped by its length and handed to `skipped` (newer peers may
    /// add types); a known type that does not decode is fatal: later pushes rethrow it.
    public mutating func push(_ bytes: Data, skipped: (UInt8) -> Void = { _ in }) throws -> [TapMessage] {
        var out: [TapMessage] = []
        for body in try buffer.push(bytes) {
            do { out.append(try TapMessage(body: body)) } catch let WireError.unknownType(type) {
                skipped(type)
            } catch {
                throw buffer.fail(error as? WireError ?? .malformed)
            }
        }
        return out
    }
}
