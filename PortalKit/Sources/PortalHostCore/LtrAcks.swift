import Foundation
import PortalKit

/// Frame -> long-term-reference token for the last 2 s, and which acknowledgements go to the game -> .claude/host.md § ltr
/// Fixed storage indexed by frame number: no allocation per frame or per `ack`.
struct LtrAcks {
    static let keepNs: UInt64 = 2_000_000_000
    /// 2 s at up to 120 frames a second.
    static let capacity = 256

    private struct Entry { var frame: UInt32, token: Int32, size: UInt32, atNs: UInt64, used: Bool }
    private var entries = [Entry](repeating: Entry(frame: 0, token: -1, size: 0, atNs: 0, used: false), count: capacity)
    /// The picture size (`width << 16 | height`) of the newest frame; a frame of another size is never acknowledged.
    private var size: UInt32?
    /// The newest frame whose token went to the game.
    private(set) var lastAcked: UInt32?

    /// A frame the game sent (`token` -1 = none).
    mutating func frame(_ frame: UInt32, token: Int32, width: UInt16, height: UInt16, nowNs: UInt64) {
        let s = UInt32(width) << 16 | UInt32(height)
        size = s
        entries[Int(frame % UInt32(Self.capacity))] = Entry(frame: frame, token: token, size: s, atNs: nowNs, used: true)
    }

    /// The token to acknowledge for the device's `ack(frame)`, or nil: no token, unknown or older than 2 s, of an
    /// earlier picture size than the newest frame's, or not newer than the last acknowledged frame.
    mutating func ack(_ frame: UInt32, nowNs: UInt64) -> Int32? {
        let e = entries[Int(frame % UInt32(Self.capacity))]
        guard e.used, e.frame == frame, e.token >= 0, nowNs &- e.atNs <= Self.keepNs, e.size == size,
              lastAcked.map({ frame > $0 }) ?? true else { return nil }
        lastAcked = frame
        return e.token
    }

    /// A new game (frame numbers restart) or a stopped one: nothing is known.
    mutating func clear() { self = LtrAcks() }
}

/// Sizes of the newest 1024 frames of each kind the game sent (bytes), for the exit line's medians -> .claude/host.md § ltr
struct FrameSizes {
    static let window = 1024
    private var samples = [[Int]](repeating: [Int](repeating: 0, count: window), count: 3)
    private(set) var counts = [0, 0, 0]

    mutating func add(_ bytes: Int, mark: FrameMark) {
        let k = Int(mark.rawValue)
        samples[k][counts[k] % Self.window] = bytes
        counts[k] += 1
    }

    /// Median of the newest (up to 1024) of a kind; 0 when none.
    func median(_ mark: FrameMark) -> Int {
        let k = Int(mark.rawValue), n = min(counts[k], Self.window)
        guard n > 0 else { return 0 }
        return samples[k].prefix(n).sorted()[n / 2]
    }
}
