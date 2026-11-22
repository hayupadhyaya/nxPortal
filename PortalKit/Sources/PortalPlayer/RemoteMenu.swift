import Foundation

/// What the Siri Remote's Menu and Play/Pause do while a game plays on Apple TV -> .claude/client.md § tv
/// One rule, one place: the remote opens the in-play menu, Menu closes it, and a controller's B that has just closed it
/// is not read a second time as the system's Menu press (while the menu is open the system turns B into Menu).
public struct RemoteMenuRule: Sendable {
    public enum Press: Sendable { case menu, playPause }
    public enum Action: Sendable, Equatable { case open, close, leave, ignore }
    /// A Menu press this soon after the controller's B closed the menu is the same press.
    public static let backWindow: TimeInterval = 0.4
    private var lastBackAt: TimeInterval?

    public init() {}

    /// The controller's B closed the menu (`ControllerInput.onBack`).
    public mutating func controllerBack(at now: TimeInterval) { lastBackAt = now }

    /// `allowed`: the menu may open (not over the ended card or the "reconnecting" screen, where Menu is "Back to games").
    public mutating func press(_ press: Press, menuOpen: Bool, allowed: Bool, at now: TimeInterval) -> Action {
        switch press {
        case .menu:
            if let last = lastBackAt, now - last >= 0, now - last < Self.backWindow { return .ignore }
            if menuOpen { return .close }
            return allowed ? .open : .leave
        case .playPause:
            return !menuOpen && allowed ? .open : .ignore
        }
    }
}
