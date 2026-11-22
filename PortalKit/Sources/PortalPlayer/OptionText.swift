import Foundation

/// Every sentence the per-game options show; English for now -> .claude/client.md § app
/// The labels, notes and values of the rows themselves are the Host's (cleaned by `OptionClean`), not written here.
public enum OptionText {
    public enum Chip: Equatable, Sendable {
        case changed, atDefault
        public var text: String { self == .changed ? OptionText.changed : OptionText.atDefault }
    }

    public static let title = "Options"
    public static let untitledSection = "Options"
    public static let caption = "Tested defaults from the game"
    public static let changed = "Changed"
    public static let atDefault = "Default"
    /// A kind this build does not know, or a row whose list cannot be used.
    public static let cannotChange = "This app cannot change it"
    public static let noOptions = "This game has no options to set here."
    public static let loading = "Loading options…"
    public static let couldNotLoad = "Could not load this game's options."
    public static let reset = "Reset to tested defaults"
    public static let footer = "Changes apply at the next start."
    public static let allOptions = "All game options"
    public static let showFewer = "Show fewer options"
    public static let nextStartTitle = "Next start of this game"
    /// The phone menu's page name (the group title is too long for a segment).
    public static let nextStartTab = "Next start"
    public static let nowTab = "Now"
    public static let newConnectionTab = "New connection"
    /// Used when the picker has three pages: "New connection" is cut off in a third of a phone's panel.
    public static let newConnectionShortTab = "Connection"
    public static let nextStartCaption = "From the game's options"
    public static let resetNotSent = "The options were not reset. The Mac is not answering."

    /// "6 more options" (the row that opens the rest of a list).
    public static func moreRow(count: Int) -> String { count == 1 ? "1 more option" : "\(count) more options" }

    public static func nextStartNote(game: String) -> String { "These apply the next time \(game) starts." }

    /// The Host did not take a value (it names the variable; the label is the row's).
    public static func rejected(label: String) -> String { "\(label) was not changed: the Mac did not accept that value." }

    /// The Mac keeps choices for as many games as it can; this game has none yet.
    public static let macFull = "This change was not kept: the Mac already keeps choices for as many games as it can."

    /// The Mac did not answer within the wait: what it did with the change is not known.
    public static func didNotAnswer(label: String) -> String { "\(label) may not have changed. The Mac did not answer." }

    /// A change that could not be sent.
    public static func notSent(label: String) -> String { "\(label) was not changed. The Mac is not answering." }

    /// The picture size sentence of the page names the game's own render-scale row by its label.
    public static func sizeHint(label: String) -> String { "A larger picture needs a higher \(label)." }

    /// Spoken value of a row: its label and value, with "changed" when it is the person's choice.
    public static func accessibilityValue(value: String, chip: Chip?) -> String {
        chip == nil ? value : "\(value), \(chip!.text)"
    }
}
