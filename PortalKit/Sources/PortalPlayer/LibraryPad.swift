import Foundation
import GameController

/// A game controller's Y in the library: on the focused tile it opens that game's page (`§ screen-game-page`).
/// Reads only each pad's Y (its own `pressedChangedHandler`, so `ControllerInput`'s pad handler, used while playing, is
/// untouched). The view sets `focused` and `onOptions` and forwards nothing else -> .claude/client.md § input
@MainActor public final class LibraryPad {
    /// The title ID of the focused tile (nil: none); set by the view.
    public var focused: String?
    /// Called once per press of Y with the focused title ID.
    public var onOptions: (@MainActor (String) -> Void)?
    /// True while the library is the frontmost thing: no sheet, page or game over it (set by the view).
    public var frontmost = true
    /// Controllers whose Y is down now (per controller; a controller that goes takes its entry with it).
    private var held: Set<ObjectIdentifier> = []
    private static let unknown = ObjectIdentifier(LibraryPad.self)  // tests and callers without an identity
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var attached: [GCController] = []

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachAll() }
            },
            nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
                let gone = (n.object as? GCController).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { if let gone { self?.controllerGone(gone) } }
            },
        ]
        attachAll()
    }

    public func stop() {
        guard started else { return }
        started = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        for c in attached { c.extendedGamepad?.buttonY.pressedChangedHandler = nil }
        attached = []
        held = []
    }

    private func attachAll() {
        for c in GCController.controllers() where c.extendedGamepad != nil && !attached.contains(where: { $0 === c }) {
            attached.append(c)
            let id = ObjectIdentifier(c)
            c.extendedGamepad?.buttonY.pressedChangedHandler = { @Sendable [weak self] _, _, pressed in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.yChanged(pressed, from: id) } }
            }
        }
    }

    /// Y went down or up. A press with a focused tile opens its options once; holding does not repeat.
    /// A controller disconnected: its held Y goes with it, so the next controller's first press counts.
    func controllerGone(_ id: ObjectIdentifier) {
        held.remove(id)
        attached.removeAll { ObjectIdentifier($0) == id }
    }

    /// Y of controller `id` went down or up. A press (a new edge of that controller) with a focused tile opens its options
    /// once, only while `frontmost`; holding does not repeat, and a Y held while a sheet closes is not a new press.
    func yChanged(_ pressed: Bool, from id: ObjectIdentifier? = nil) {
        let key = id ?? Self.unknown
        let rising = pressed && !held.contains(key)
        if pressed { held.insert(key) } else { held.remove(key) }
        guard rising, frontmost, let title = focused else { return }
        onOptions?(title)
    }
}
