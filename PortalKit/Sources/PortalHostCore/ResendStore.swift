import Foundation
import PortalKit

/// The video fragments of the last 0.5 s (at most 64 MB), unsealed: a resend is sealed afresh, since the receiver
/// refuses a replayed counter -> .claude/host.md § service
struct ResendStore {
    static let maxPerNack = 512
    static let minResendGapNs: UInt64 = 4_000_000

    /// Asks refused since the store was made (`clear` keeps them).
    struct Refused: Equatable, Sendable {
        /// A frame not held (never sent, older than the hold, or from a stopped game).
        var unknownFrame = 0
        /// An index at or past the frame's fragment count.
        var badIndex = 0
        /// The same fragment again within 4 ms.
        var tooSoon = 0
        /// A `nack` that would have resent more than 512 fragments.
        var overLimit = 0
        /// A resend past the session's budget (the video bitrate, 0.2 s deep).
        var overBudget = 0
    }

    private struct Entry {
        var at: UInt64
        var fragments: [VideoFragment?]
        /// Last resend per index; 0 = never.
        var resentAt: [UInt64]
    }

    let holdNs: UInt64, maxBytes: Int
    private var entries: [UInt32: Entry] = [:]
    /// Frame numbers, oldest first.
    private var order: [UInt32] = []
    private(set) var bytes = 0
    private(set) var refused = Refused()
    /// Resend budget, a token bucket in payload bytes: refills at the video bitrate, 0.2 s of it deep.
    static let budgetDepthSeconds = 0.2
    private var bytesPerSecond: Double
    private var tokens: Double
    private var refilledNs: UInt64?

    init(holdNs: UInt64 = 500_000_000, maxBytes: Int = 64 << 20, bitsPerSecond: UInt32 = HostDefaults.bitrate) {
        self.holdNs = holdNs
        self.maxBytes = maxBytes
        bytesPerSecond = Double(bitsPerSecond) / 8
        tokens = bytesPerSecond * Self.budgetDepthSeconds
    }

    /// The session's current video bitrate (what the tap was told).
    mutating func setBitrate(_ bitsPerSecond: UInt32) {
        bytesPerSecond = Double(bitsPerSecond) / 8
        tokens = min(tokens, depth)
    }

    private var depth: Double { bytesPerSecond * Self.budgetDepthSeconds }
    /// The rate the budget refills at.
    var bitsPerSecond: UInt32 { UInt32((bytesPerSecond * 8).rounded()) }

    /// One fragment as it goes out. A fragment whose slot is already filled (or whose count differs) starts the
    /// frame number afresh (a new game numbers from 0 again).
    mutating func keep(_ f: VideoFragment, nowNs now: UInt64) {
        evict(now)
        let i = Int(f.index)
        if let e = entries[f.frame], e.fragments.count != Int(f.count) || e.fragments[i] != nil { remove(f.frame) }
        if entries[f.frame] == nil {
            entries[f.frame] = Entry(at: now, fragments: Array(repeating: nil, count: Int(f.count)),
                                     resentAt: Array(repeating: 0, count: Int(f.count)))
            order.append(f.frame)
        }
        entries[f.frame]!.fragments[i] = f
        bytes += f.payload.count
        while bytes > maxBytes, let oldest = order.first, oldest != f.frame { remove(oldest) }
    }

    /// The held fragments of `frame` at `indices` (none = all), in the order asked; unknown frame or index -> nothing.
    func fragments(frame: UInt32, indices: [UInt16]) -> [VideoFragment] {
        guard let e = entries[frame] else { return [] }
        if indices.isEmpty { return e.fragments.compactMap { $0 } }
        return indices.compactMap { Int($0) < e.fragments.count ? e.fragments[Int($0)] : nil }
    }

    /// What a `nack` resends: held fragments not resent in the last 4 ms, at most 512; the rest is counted.
    mutating func resend(frame: UInt32, indices: [UInt16], nowNs now: UInt64) -> [VideoFragment] {
        evict(now)
        // Taken out and put back: a copy held beside the dictionary's would make the writes copy `resentAt`.
        guard var e = entries.removeValue(forKey: frame) else { refused.unknownFrame += 1; return [] }
        defer { entries[frame] = e }
        if let last = refilledNs, now > last { tokens = min(depth, tokens + bytesPerSecond * Double(now - last) / 1e9) }
        refilledNs = max(refilledNs ?? now, now)
        var out: [VideoFragment] = []
        func take(_ i: Int) -> Bool {
            guard i < e.fragments.count else { refused.badIndex += 1; return true }
            guard let f = e.fragments[i] else { return true }
            if e.resentAt[i] != 0, now &- e.resentAt[i] < Self.minResendGapNs { refused.tooSoon += 1; return true }
            guard out.count < Self.maxPerNack else { refused.overLimit += 1; return false }
            guard tokens >= Double(f.payload.count) else { refused.overBudget += 1; return false }
            tokens -= Double(f.payload.count)
            e.resentAt[i] = now
            out.append(f)
            return true
        }
        if indices.isEmpty {
            for i in e.fragments.indices where !take(i) { break }
        } else {
            for i in indices where !take(Int(i)) { break }
        }
        return out
    }

    /// A frame the sender dropped unsent: a `nack` for it finds nothing.
    mutating func discard(frame: UInt32) { remove(frame) }

    mutating func clear() {
        tokens = depth
        refilledNs = nil
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        bytes = 0
    }

    private mutating func evict(_ now: UInt64) {
        while let oldest = order.first, let e = entries[oldest], now > e.at, now - e.at > holdNs { remove(oldest) }
    }

    private mutating func remove(_ frame: UInt32) {
        guard let e = entries.removeValue(forKey: frame) else { return }
        bytes -= e.fragments.reduce(0) { $0 + ($1?.payload.count ?? 0) }
        if let i = order.firstIndex(of: frame) { order.remove(at: i) }
    }
}
