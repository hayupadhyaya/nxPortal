import Foundation

/// Every sentence the on-screen controller shows or speaks; the app's `Strings` only forwards -> .claude/client.md § input
public enum TouchText {
    /// The in-play menu's row and Settings' default for new games.
    public static let groupTitle = "On-screen controls"
    public static let layoutTitle = "Touch layout"
    public static let layoutForNewGames = "Layout for new games"
    public static let layoutNote = "Simple has the shoulders, sticks and keys; Full adds the D-pad, the click keys and a camera stick on the right third."
    public static let hapticsTitle = "Haptics on touch controls"
    public static let hapticsNote = "A light tap when you press an on-screen control."
    public static let acknowledgements = "Acknowledgements"
    /// The glass note when a game controller takes over (shown 3 s).
    public static let controllerConnected = "Controller connected \u{00B7} touch controls hidden"
    /// Apple TV: over the picture until a game controller (never the Siri Remote) is connected.
    public static let connectController = "Connect a controller to play."
    /// VoiceOver's name for the gear that opens the in-play menu.
    public static let menuButton = "Menu"
    /// The touch area as a whole, for VoiceOver (direct touch passes the fingers through).
    public static let padName = "On-screen controller"

    public static func name(_ l: TouchLayout) -> String {
        switch l {
        case .flat: "Simple (2D)"
        case .full: "Full (3D)"
        }
    }

    /// The layout rows' choices, in the order shown.
    public static var choices: [(TouchLayout, String)] { TouchLayout.allCases.map { ($0, name($0)) } }

    /// The layout rows (the menu's and Settings') show only with no game controller connected.
    public static func showsLayoutRow(gameControllers: Int) -> Bool { gameControllers == 0 }
}
