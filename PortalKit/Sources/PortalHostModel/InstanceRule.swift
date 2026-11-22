#if os(macOS)
import Foundation

/// Which of several instances of the app keeps running -> .claude/host.md § app
public enum InstanceRule {
    /// One process of the app: its pid and its start time (microseconds since 1970; nil = the system would not say).
    public struct Instance: Equatable, Sendable {
        public var pid: Int32
        public var startedAt: Int64?
        public init(pid: Int32, startedAt: Int64?) { self.pid = pid; self.startedAt = startedAt }
    }

    /// A starting instance exits when another is older: it started earlier, or its start time cannot be read (never two Hosts),
    /// or the start times are equal and its pid is lower. An instance that cannot read its own start time leaves when any other
    /// runs. Only a starting instance decides: two starts that see each other leave exactly one, and a pid that wrapped round
    /// does not make a newcomer the survivor.
    public static func shouldExit(me: Instance, others: [Instance]) -> Bool {
        others.contains { other in
            guard let theirs = other.startedAt, let mine = me.startedAt else { return true }
            return theirs < mine || (theirs == mine && other.pid < me.pid)
        }
    }
}
#endif
