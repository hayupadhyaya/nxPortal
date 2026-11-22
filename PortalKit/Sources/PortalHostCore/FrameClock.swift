#if os(macOS)
import Foundation

/// The game's own frame rate and frame times, from the capture times of the video frames the tap delivers (the game's
/// clock, not arrival): `push` per frame, `take` once a second -> .claude/host.md § load
/// Kept: at most `capacity` gaps; a frame whose time does not advance is ignored; `take` keeps the last frame, so the gap
/// that spans a reading (a stall) counts in the next one.
struct FrameClock {
    static let capacity = 1_024
    private var gapsNs: [UInt64] = []
    private var lastNs: UInt64?

    /// Forgets the last frame too: after a pause or a preparation the next frame's gap is not a stall.
    mutating func restart() { gapsNs.removeAll(keepingCapacity: true); lastNs = nil }

    var retained: Int { gapsNs.count }

    mutating func push(captureNs: UInt64) {
        guard let last = lastNs else { lastNs = captureNs; return }
        guard captureNs > last else { return }
        if gapsNs.count == Self.capacity { gapsNs.removeFirst(Self.capacity / 2) }  // an old half goes; the newest gaps stay
        gapsNs.append(captureNs - last)
        lastNs = captureNs
    }

    /// The gaps since the last `take` (or the start), then forgets them. nil with no gap.
    mutating func take() -> (fps: Double, meanMs: Double, p95Ms: Double, maxMs: Double)? {
        defer { gapsNs.removeAll(keepingCapacity: true) }  // the last frame stays: a stall across a reading is a gap
        guard !gapsNs.isEmpty else { return nil }
        let sorted = gapsNs.sorted()
        let total = Double(gapsNs.reduce(0, +))
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1  // nearest rank
        return (fps: Double(gapsNs.count) / (total / 1e9),
                meanMs: total / Double(gapsNs.count) / 1e6,
                p95Ms: Double(sorted[max(0, min(rank, sorted.count - 1))]) / 1e6,
                maxMs: Double(sorted[sorted.count - 1]) / 1e6)
    }
}
#endif
