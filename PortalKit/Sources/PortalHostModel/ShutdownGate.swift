#if os(macOS)
import Foundation

/// The Host's stop, run once however many times it is asked for, and waited for at most `limit` seconds: a second request
/// (a second Quit, a signal) joins the first and returns when it does -> .claude/host.md § app
@MainActor
public final class ShutdownGate {
    private let limit: TimeInterval
    private let finally: @MainActor () -> Void
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var begun = false
    private var finished = false

    /// `finally` runs once, when the stop has finished or the limit has passed, whichever is first.
    public init(limit: TimeInterval, finally: @escaping @MainActor () -> Void = {}) { self.limit = limit; self.finally = finally }

    public func run(_ work: @escaping @MainActor () async -> Void) async {
        if !begun {
            begun = true
            let limit = limit
            Task { await work(); finish() }
            Task { try? await Task.sleep(nanoseconds: UInt64(max(limit, 0) * 1_000_000_000)); finish() }
        }
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        finally()
        let all = waiters
        waiters = []
        for c in all { c.resume() }
    }
}
#endif
