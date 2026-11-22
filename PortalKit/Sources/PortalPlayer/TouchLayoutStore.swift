import Foundation

/// Which touch layout each game uses, kept per title on this device (`touchLayout.<titleID>`); a game never chosen
/// gets `fallback` (the Settings default). -> .claude/client.md § input
public struct TouchLayoutStore: Sendable {
    // UserDefaults is documented thread-safe; it is only not annotated Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let fallback: TouchLayout

    public init(defaults: UserDefaults = .standard, fallback: TouchLayout = .flat) {
        self.defaults = defaults
        self.fallback = fallback
    }

    private func key(_ titleID: String) -> String { "touchLayout.\(titleID)" }

    public func layout(for titleID: String) -> TouchLayout {
        titleID.isEmpty ? fallback : defaults.string(forKey: key(titleID)).flatMap(TouchLayout.init(rawValue:)) ?? fallback
    }

    /// A game with no title is nobody's: nothing is stored for it.
    public func set(_ l: TouchLayout, for titleID: String) {
        guard !titleID.isEmpty else { return }
        defaults.set(l.rawValue, forKey: key(titleID))
    }
}
