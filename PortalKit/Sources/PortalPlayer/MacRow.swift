import Foundation

/// What the Macs list shows for one Mac -> .claude/client.md § model
public enum MacState: Equatable, Sendable { case looking, connecting, connected, unreachable }

public struct MacRow: Equatable, Identifiable, Sendable {
    /// The Mac's discovery ID (`Identity.discoveryID` of its key); the name for a Host that sends none.
    public var id: String
    public var name: String
    public var paired: Bool
    /// Listed by discovery now (the current Mac while its session is open).
    public var reachable: Bool
    public var current: Bool
    /// The game running on this Mac, while one does.
    public var playing: String?
}

extension MacRow {
    /// The dot beside a row's status: none, or the palette's positive / warning colour.
    public enum Dot: Equatable, Sendable { case positive, warning }

    /// The Macs list's status line and dot for this row; the current Mac's follows the session (`state`).
    public func status(state: MacState) -> (text: String, dot: Dot?) {
        if !paired { return ("Pair", nil) }
        if current {
            if let game = playing { return (Messages.playing(game), .positive) }
            switch state {
            case .connected: return ("Connected", .positive)
            case .connecting: return ("Connecting…", .warning)
            case .looking: return ("Looking…", nil)
            case .unreachable: return reachable ? ("Not answering", .warning) : ("Not found", nil)
            }
        }
        return (reachable ? "Found" : "Not found", nil)
    }

    /// VoiceOver's value for the row: its status, and ", current" for the Mac in use.
    public func accessibilityValue(state: MacState) -> String { status(state: state).text + (current ? ", current" : "") }
}
