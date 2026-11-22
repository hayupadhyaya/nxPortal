import Foundation
import PortalKit

/// The library's words and tile states, for the views and VoiceOver (`§ look-access`) -> .claude/client.md § app
public enum LibraryText {
    /// First run: "Still looking…" shows once discovery has looked this long without finding a Mac.
    public static let stillLookingAfter: TimeInterval = 30
    public static func showsStillLooking(since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= stillLookingAfter
    }

    /// What a tile shows besides its icon; `preparing` carries the percent when the Host reports progress.
    public enum TileState: Equatable, Sendable { case normal, paused, rebuild, unreachable, preparing(percent: Int?) }

    /// The first letters of the first two words, upper-cased: a tile without an icon.
    public static func initials(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// Not reachable greys every tile; a game that cannot stream is greyed for a rebuild.
    public static func tileState(_ game: GameEntry, reachable: Bool, preparing: Preparing? = nil) -> TileState {
        // A last-known list shows nothing live (greyed, "Mac not reachable"); the ring is the live library's, never for a
        // paused game or one that cannot stream.
        if !reachable { return .unreachable }
        if let preparing, game.streamable, game.state != .paused {
            return .preparing(percent: PreparingText.display(preparing) == .waiting ? nil : preparing.percent)
        }
        if !game.streamable { return .rebuild }
        return game.state == .paused ? .paused : .normal
    }

    public static func tileValue(_ state: TileState) -> String {
        switch state {
        case .normal: ""
        case .paused: "Paused"
        case .rebuild: "Needs a rebuild on the Mac"
        case .unreachable: "Mac not reachable"
        case let .preparing(percent): percent.map { "Preparing, \($0) percent" } ?? "Preparing"
        }
    }

    public static let tileHint = "Plays the game."

    /// Apple TV: the caption beside the Continue card for the tile that has focus (`§ screen-library`).
    public static let focusedLabel = "Focused"
    public static let focusHint = "Press and hold for options"
    /// The line under the focused game's name: its state, or "Last played here" for the game last played; nil with nothing to say.
    public static func focusState(_ state: TileState, lastPlayed: Bool) -> String? {
        switch state {
        case .normal: lastPlayed ? "Last played here" : nil
        default: tileValue(state)
        }
    }
    public static let rebuildNeeded = "Rebuild needed"

    /// `preparing`: the Mac's live preparation of this game; the card then says how far it is, as the tile does. `playsHere`:
    /// this session plays the game (`ClientModel.playChosen`); a library session never reads "Playing".
    public static func continueState(_ game: GameEntry, preparing: Preparing? = nil, playsHere: Bool = true) -> String {
        if let preparing, game.state == .running || game.state == .starting {
            return PreparingText.tileCaption(percent: PreparingText.display(preparing) == .waiting ? nil : preparing.percent)
        }
        return switch game.state {
        case .paused: "Paused"
        case .starting: "Starting"
        // Running in a session that does not play it: the pause it owes has not gone out yet.
        case .running: playsHere ? "Playing" : "Preparing"
        case .idle: "Last played here"
        }
    }

    /// The Continue card as one VoiceOver element.
    public static func continueLabel(_ game: GameEntry, preparing: Preparing? = nil, playsHere: Bool = true) -> String {
        "Continue, \(game.name), \(continueState(game, preparing: preparing, playsHere: playsHere).lowercased())"
    }

    /// Resume a paused or running game; Play one that is not running.
    public static func continueAction(_ game: GameEntry) -> String { game.state == .idle ? "Play" : "Resume" }

    public static let loading = "Loading games\u{2026}"

    /// Connected, nothing listed or cached yet, no list received: the library is loading, not empty.
    /// A list that failed or timed out is not loading any more (`showsCouldNotLoad`).
    public static func showsLoading(connected: Bool, listed: Bool, games: Int, failed: Bool = false) -> Bool {
        connected && !listed && games == 0 && !failed
    }

    /// Connected, nothing listed or cached, and the list request failed or timed out: the sentence with Retry.
    public static func couldNotLoad(mac: String) -> String { "Could not load the games on \(mac)." }
    public static func showsCouldNotLoad(connected: Bool, listed: Bool, games: Int, failed: Bool) -> Bool {
        connected && !listed && games == 0 && failed
    }

    public static func empty(mac: String) -> String {
        "No games on \(mac) yet. Games that support streaming show up here when they are in the Mac's game folders."
    }

    public static func gameCount(_ n: Int) -> String { n == 1 ? "1 game" : "\(n) games" }
}
