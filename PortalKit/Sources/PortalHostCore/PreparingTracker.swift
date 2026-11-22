import Foundation
import PortalKit

/// What the Host says about a game's graphics preparation.
enum TrackerState: Equatable {
    case none
    /// Preparing; the newest progress when under 5 s old (and not 0 of 0), else nil = waiting for the game.
    case preparing(Preparing?)
}

/// Pure rules; time (uptime nanoseconds) arrives as an argument -> .claude/host.md § service
/// Preparing: from launch until the first picture, and again while the game is alive, not paused, and its newest picture is
/// over 2 s old. Never for a paused game.
struct PreparingTracker {
    static let silenceNs: UInt64 = 2_000_000_000
    static let progressLifeNs: UInt64 = 5_000_000_000

    private var alive = false
    private var paused = false
    private var pictured = false
    private var lastPicture: UInt64 = 0
    private var newest: Preparing?
    private var newestAt: UInt64 = 0
    /// How far the current phase had got, kept through a "0 of 0" message (no count now) that replaces `newest`.
    private var reached: (phase: UInt8, done: UInt32)?

    mutating func launched(now: UInt64) {
        self = PreparingTracker()
        alive = true
    }

    /// Any picture ends the preparation and drops the progress that came before it.
    mutating func picture(now: UInt64) {
        guard alive else { return }
        pictured = true
        lastPicture = now
        newest = nil
    }

    /// `done` never exceeds a non-zero `total` and never falls within a phase; a new phase number starts afresh.
    /// Progress for a paused game is ignored.
    mutating func progress(_ p: Preparing, now: UInt64) {
        guard alive, !paused else { return }
        var q = p
        if q.total > 0 { q.done = min(q.done, q.total) }
        if q.total > 0 {
            if let r = reached, r.phase == q.phase { q.done = max(q.done, min(r.done, q.total)) }
            reached = (q.phase, q.done)
        }
        newest = q
        newestAt = now
    }

    /// `paused`: the game has really been told to pause. Resuming restarts the 2 s silence from now.
    mutating func pausedChanged(_ paused: Bool, now: UInt64) {
        guard alive, self.paused != paused else { return }
        self.paused = paused
        if !paused, pictured { lastPicture = now }
    }

    mutating func ended() { self = PreparingTracker() }

    func state(now: UInt64) -> TrackerState {
        guard alive, !paused else { return .none }
        if pictured, now &- lastPicture <= Self.silenceNs { return .none }
        if let p = newest, p.total > 0, now &- newestAt < Self.progressLifeNs { return .preparing(p) }
        return .preparing(nil)
    }
}
