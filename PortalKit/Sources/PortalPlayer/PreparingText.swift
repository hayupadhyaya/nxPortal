import Foundation
import PortalKit

/// The words and numbers of the preparing screen, the waiting screen and the tile ring; the app's `Strings` only forwards
/// here -> .claude/client.md § app
public enum PreparingText {
    /// A phase with nothing to count (total 0) is waiting for the game; the phase's number is never shown.
    public enum Display: Equatable, Sendable { case progress(Preparing), waiting }

    public static let preparingTitle = "Preparing graphics for this Mac"
    public static let firstStartNote = "The first start on a Mac takes a few minutes. Later starts are quick."
    /// The in-play menu's note under Disconnect (a preparing game pauses only once it is ready).
    public static func disconnectNote(preparing: Bool) -> String {
        preparing ? "Disconnect shows the games; the game goes on preparing and pauses when it is ready. Quit ends it."
            : "Disconnect pauses the game and shows the games. Quit ends it."
    }
    public static let leaveNote = "You can leave: this goes on."
    public static let waitingTitle = "Waiting for the game"
    public static func waitingBody(game: String, mac: String) -> String {
        "\(game) is starting on \(mac). Nothing has come back from it yet; this can take a minute."
    }

    public static func display(_ p: Preparing) -> Display { p.total == 0 ? .waiting : .progress(p) }

    /// "12,400 of 34,649": the phase's own numbers, grouped by the locale.
    public static func count(_ p: Preparing, locale: Locale = .current) -> String {
        let done = min(p.done, p.total)
        return "\(Int(done).formatted(.number.locale(locale))) of \(Int(p.total).formatted(.number.locale(locale)))"
    }

    /// "3 min 12 s so far".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3_600 { return "\(s / 3_600) h \((s % 3_600) / 60) min so far" }
        if s >= 60 { return "\(s / 60) min \(s % 60) s so far" }
        return "\(s) s so far"
    }

    /// The waiting screen's clock: "0:42", "1:02:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3_600 { return String(format: "%d:%02d:%02d", s / 3_600, (s % 3_600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// One element: "Preparing graphics, 36 percent".
    public static func accessibilityValue(_ p: Preparing) -> String {
        switch display(p) {
        case .waiting: waitingTitle
        case .progress: "Preparing graphics, \(p.percent) percent"
        }
    }

    /// Said when the percent passes 25, 50 or 75 (the newest of those crossed between the two); nothing else, 100 included.
    public static func announcement(from old: Int?, to new: Int) -> String? {
        guard let old, new > old else { return nil }
        guard let crossed = [75, 50, 25].first(where: { old < $0 && new >= $0 }) else { return nil }
        return "Preparing graphics, \(crossed) percent"
    }

    /// Announcements over a whole preparation: it remembers the last percent through "waiting" gaps (no percent), so a
    /// crossing is said when progress resumes. The first percent ever seen is never announced.
    public struct Announcer: Equatable, Sendable {
        private var last: Int?
        public init() {}
        /// The sentence to say for the newest percent (nil = none now: a gap keeps what was last seen).
        public mutating func next(_ percent: Int?) -> String? {
            guard let percent else { return nil }
            defer { last = percent }
            return PreparingText.announcement(from: last, to: percent)
        }
    }

    /// The starting card's first line.
    public static func header(game: String, mac: String) -> String { "\(game) on \(mac)" }

    /// The tile's caption: "Preparing 36 %".
    public static func tileCaption(percent: Int?) -> String { percent.map { "Preparing \($0) %" } ?? "Preparing" }
}
