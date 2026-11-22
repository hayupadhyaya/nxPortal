#if os(tvOS)
import GameController
import PortalPlayer
import SwiftUI
import UIKit

/// The play screen in a `GCEventViewController` (Apple TV) -> `.claude/client.md § tv`
/// While a game plays `controllerUserInteractionEnabled` is false: a game controller's buttons reach only the game (the
/// system would otherwise turn B into Menu and A into Select). While anything covers the game (`PlayRoute`: the in-play menu,
/// the reconnecting, ended and starting cards) it is true, so the controller and the remote move focus. The Siri Remote's Menu and Play/Pause arrive as presses here and are the app's (`onPress`);
/// Menu is never passed on, so it cannot leave the app from the play screen.
struct PlayHost<Content: View>: UIViewControllerRepresentable {
    /// Who has the controller (`PlayRoute`): the game while playing, the focus engine while anything covers it.
    let route: PlayRoute
    let onPress: (RemoteMenuRule.Press) -> Void
    let content: Content

    init(route: PlayRoute, onPress: @escaping (RemoteMenuRule.Press) -> Void, @ViewBuilder content: () -> Content) {
        self.route = route; self.onPress = onPress; self.content = content()
    }

    func makeUIViewController(context: Context) -> PlayHostController<Content> {
        PlayHostController(rootView: content)
    }

    func updateUIViewController(_ controller: PlayHostController<Content>, context: Context) {
        controller.host.rootView = content
        controller.onPress = onPress
        controller.controllerUserInteractionEnabled = route == .focus
    }
}

final class PlayHostController<Content: View>: GCEventViewController {
    let host: UIHostingController<Content>
    var onPress: ((RemoteMenuRule.Press) -> Void)?

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        controllerUserInteractionEnabled = false  // playing: the controller is the game's
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = presses
        for press in presses {
            switch press.type {
            case .menu: onPress?(.menu); rest.remove(press)
            case .playPause: onPress?(.playPause); rest.remove(press)
            default: break
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { $0.type != .menu && $0.type != .playPause }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { $0.type != .menu && $0.type != .playPause }
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}
#endif
