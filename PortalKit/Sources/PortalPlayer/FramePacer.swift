import Foundation

/// How pictures reach the display: `immediate` shows each one on arrival, `smooth` shows one per display refresh.
public enum PicturePacing: String, Codable, Sendable, CaseIterable { case immediate, smooth }

/// Pure pacing logic for one display: `push` when a picture arrives, `refresh` once per display refresh;
/// no clock, no UIKit -> .claude/client.md § pacing
public struct FramePacer<Frame> {
    /// Pictures kept after a refresh in `smooth` (sustained): the delay it adds.
    public static var target: Int { 1 }
    /// More than this many stored after a refresh is a burst: cut to `target` at once.
    public static var ceiling: Int { target + 2 }
    /// Refreshes in a row with more than `target` stored before the oldest extras are dropped (`smooth`).
    public static var slack: Int { 6 }

    public var mode: PicturePacing
    private var stored: [Frame] = []
    private var shown = 0, late = 0, empty = 0
    /// `immediate`: pictures that count as shown in the current refresh interval (pushed, or the held one taken at its start).
    private var pushedSinceRefresh = 0
    /// `immediate`: the second picture of an interval, kept for the next refresh; never more than one.
    private var held: Frame?
    /// `smooth`: consecutive refreshes that ended with more than `target` stored.
    private var overRefreshes = 0

    public init(mode: PicturePacing) { self.mode = mode }

    /// Pictures waiting for a refresh (`smooth`).
    public var pending: Int { stored.count }

    /// A picture arrived (main queue). `immediate`: the first of an interval is returned, show it now; a later one is held for
    /// the next refresh (an older held one is dropped, late). `smooth`: kept for `refresh()`.
    public mutating func push(_ frame: Frame) -> Frame? {
        switch mode {
        case .immediate:
            // Pictures stored under `smooth` are older than this one: showing them later would step backwards.
            late += stored.count
            stored.removeAll()
            overRefreshes = 0
            if pushedSinceRefresh == 0 { pushedSinceRefresh = 1; return frame }
            if held != nil { late += 1 }
            held = frame
            return nil
        case .smooth:
            releaseHeld()
            stored.append(frame)
            return nil
        }
    }

    /// One display refresh. `smooth`: the oldest stored picture (nil when none); a burst beyond `ceiling` is cut to `target` at once,
    /// a second picture kept for `slack` refreshes in a row is dropped (late). `immediate`: the held picture, which then counts
    /// as the new interval's own; else nil, unless pictures stored under `smooth` are left: the newest once, the rest late.
    public mutating func refresh() -> Frame? {
        switch mode {
        case .immediate:
            if let newest = stored.last {
                late += stored.count - 1
                stored.removeAll()
                overRefreshes = 0
                shown += 1
                pushedSinceRefresh = 0
                return newest
            }
            if pushedSinceRefresh > 0 { shown += 1 } else { empty += 1 }
            pushedSinceRefresh = held == nil ? 0 : 1
            defer { held = nil }
            return held
        case .smooth:
            pushedSinceRefresh = 0
            releaseHeld()
            guard !stored.isEmpty else { empty += 1; return nil }
            let frame = stored.removeFirst()
            shown += 1
            if stored.count > Self.ceiling {
                dropToTarget()
            } else if stored.count > Self.target {
                overRefreshes += 1
                if overRefreshes >= Self.slack { dropToTarget() }
            } else {
                overRefreshes = 0
            }
            return frame
        }
    }

    /// A picture held under `immediate` is the newest of what a switch to `smooth` finds: it goes to the store's front.
    private mutating func releaseHeld() {
        if let h = held { stored.insert(h, at: 0); held = nil }
    }

    private mutating func dropToTarget() {
        let extra = stored.count - Self.target
        stored.removeFirst(extra)
        late += extra
        overRefreshes = 0
    }

    /// Counts since the last call (or `reset()`); resets them.
    public mutating func takeCounts() -> (shown: Int, late: Int, empty: Int) {
        defer { shown = 0; late = 0; empty = 0 }
        return (shown, late, empty)
    }

    /// Drops stored pictures and counts.
    public mutating func reset() {
        stored.removeAll()
        shown = 0; late = 0; empty = 0; pushedSinceRefresh = 0; overRefreshes = 0; held = nil
    }
}
