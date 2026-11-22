import Foundation

/// Who receives a game controller while the play screen is up -> .claude/client.md § input
/// One rule on every platform: while anything covers the picture (the in-play menu, a sheet over play, the reconnecting or
/// ended card, the starting card with its buttons) the game gets neutral input (`ControllerInput.menuOpen`) and, on Apple TV,
/// the focus engine has the controller; otherwise the game alone has it. Never both, never neither.
public enum PlayRoute: Equatable, Sendable {
    case game, focus

    /// `startingCard`: the starting / preparing card (`ClientModel.startingCard`) is over the picture; `sheet`: a sheet is
    /// presented over play (the game's page).
    public static func controller(menuOpen: Bool, trouble: TroubleStage, startingCard: Bool, sheet: Bool) -> PlayRoute {
        covered(menuOpen: menuOpen, trouble: trouble, startingCard: startingCard, sheet: sheet) ? .focus : .game
    }

    /// Something covers the picture: its input is neutral and the focus engine has the controller.
    public static func covered(menuOpen: Bool, trouble: TroubleStage, startingCard: Bool, sheet: Bool) -> Bool {
        menuOpen || sheet || trouble.covers || startingCard
    }
}

/// What the play screen itself puts over the picture: the in-play menu and a sheet presented over play (the game's page,
/// opened from the menu). The close routes close the TOP thing only -> .claude/client.md § input
public struct PlayOverlays: Equatable, Sendable {
    public var menu: Bool
    public var sheet: Bool
    public init(menu: Bool = false, sheet: Bool = false) { self.menu = menu; self.sheet = sheet }

    /// B (or the remote's Back): the sheet closes when one is up, else the menu.
    public mutating func back() {
        if sheet { sheet = false } else { menu = false }
    }

    /// Home or the menu chord: the sheet closes when one is up (only it); else the menu closes, or opens where `allowed`.
    /// False: nothing changed (the menu may not open here).
    @discardableResult
    public mutating func toggle(allowed: Bool) -> Bool {
        if sheet { sheet = false; return true }
        if menu || allowed { menu.toggle(); return true }
        return false
    }

    /// `PlayRoute.covered` with this screen's own covers.
    public func covers(trouble: TroubleStage, startingCard: Bool) -> Bool {
        PlayRoute.covered(menuOpen: menu, trouble: trouble, startingCard: startingCard, sheet: sheet)
    }
}
