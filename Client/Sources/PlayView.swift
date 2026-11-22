import PortalClientCore
import PortalKit
import PortalPlayer
import SwiftUI
import UIKit

/// The picture, full screen on black; one tap (the remote's Menu button on tvOS, a controller's Home or the menu chord)
/// opens the in-play menu (`PlayMenuView`), which closes by every route and has no timer. While it is open the game gets
/// neutral input (`ControllerInput.menuOpen`). -> `§ screen-play`
struct PlayView: View {
    let model: ClientModel
    /// The picture view and the controller reader, made on first use and then kept (a `@State` initializer expression runs on every struct init).
    @State private var parts = Parts()
    /// The in-play menu and the game's page over the play (the menu's "All game options"); the close routes close the top one.
    @State private var overlays = PlayOverlays()
    /// The numbers panel as drawn (`NumbersPanel.onSize`): the placement uses it.
    @State private var panelSize = CGSize.zero
    #if os(iOS)
    @State private var touchLayout = TouchLayout.flat
    @State private var controllerNote = false
    @State private var noteCount = 0
    @State private var controllerPresent = false
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(tvOS)
    @State private var controllerPresent = false
    /// The remote's presses and a controller's B share one rule (`RemoteMenuRule`).
    @State private var remote = RemoteMenuRule()
    #endif

    @MainActor final class Parts {
        private(set) lazy var picture = PictureUIView()
        #if os(iOS)
        private(set) lazy var touch = TouchPadView()
        #endif
        private var made: ControllerInput?

        func controller(for model: ClientModel) -> ControllerInput {
            if let made { return made }
            // `send` runs on the main queue (ControllerInput's contract), so it may reach the model directly.
            let c = ControllerInput(settings: model.settings) { input in MainActor.assumeIsolated { model.send(input) } }
            made = c
            return c
        }
    }

    private var picture: PictureUIView { parts.picture }
    private var controller: ControllerInput { parts.controller(for: model) }

    var body: some View {
        #if os(tvOS)
        PlayHost(route: covered ? .focus : .game, onPress: remotePress) { screen }
            .ignoresSafeArea()
        #else
        screen
        #endif
    }

    private var screen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PictureView(view: picture).ignoresSafeArea()
                .colorMultiply(Color(white: model.trouble.pictureBrightness)).blur(radius: model.trouble.pictureBlur)
                .overlay { if model.trouble.covers { Theme.color(Theme.palette.scrim).ignoresSafeArea().allowsHitTesting(false) } }
                .animation(reduceMotion ? nil : .easeOut(duration: Theme.motion.menu), value: model.trouble)
            #if os(iOS)
            if model.screen == .playing {
                TouchPadRepresentable(view: parts.touch).ignoresSafeArea()
                    .allowsHitTesting(!covered)
            }
            #endif
            if model.startingCard {
                StartingView(model: model)
            }
            if model.screen == .playing { TroubleView(model: model) }
            VStack(spacing: 8) {
                if model.trouble == .none {
                    if model.reconnecting { banner(Messages.connectionLost) }
                    if let text = model.message, !model.reconnecting { banner(text) }
                }
                Spacer()
            }
            .padding()
            if model.screen == .playing, !numbersUnderMenu { numbers }
            #if os(iOS)
            if controllerNote {
                Text(Strings.controllerConnected).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.color(Theme.palette.text))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glass(.thick, radius: Theme.radii.banner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 52)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            #endif
            #if os(tvOS)
            if !controllerPresent, !menu, model.screen == .playing, model.trouble == .none, model.preparing == nil {
                Text(Strings.connectController).font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.color(Theme.palette.text))
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .glass(.thick, radius: Theme.radii.banner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 90)
                    .allowsHitTesting(false)
            }
            #endif
            if menu {
                PlayMenuView(model: model, onClose: closeMenu, touchLayout: touchLayoutBinding,
                             onAllOptions: { id in if !id.isEmpty { gamePage = true } })
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: reduceMotion ? Theme.motion.reduced : Theme.motion.menu), value: menu)
        #if os(iOS)
        .animation(.easeOut(duration: reduceMotion ? Theme.motion.reduced : Theme.motion.banner), value: controllerNote)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        // neutral input while anything covers the game (on Apple TV the same rule gives the focus engine the controller)
        .onChange(of: covered, initial: true) { _, now in controller.menuOpen = now }
        .sheet(isPresented: Binding(get: { gamePage && !(model.gameState?.titleID ?? "").isEmpty }, set: { gamePage = $0 })) {
            NavigationStack {
                GamePage(model: model, titleID: model.gameState?.titleID ?? "", onPlay: { gamePage = false })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.done) { gamePage = false } } }
            }
        }
        #if os(iOS)
        .onChange(of: touchBlockers, initial: true) { _, now in parts.touch.setBlockers(now) }
        .onChange(of: model.settings.touchHaptics) { _, on in parts.touch.haptics = on }
        #endif
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        #if os(iOS)
        .onChange(of: model.reconnecting) { _, reconnecting in
            // The screen may sleep while "Trying again…" shows.
            UIApplication.shared.isIdleTimerDisabled = !reconnecting
        }
        #endif
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Theme.color(Theme.palette.text))
            .padding(10)
            .glass(.thick, radius: Theme.radii.banner)
    }

    /// Never takes a touch. On iOS the panel is placed by `TouchPanel` from its MEASURED size: with the touch controls shown at
    /// the top centre under the row of the three centre controls, without them top left and below the gear where it would
    /// reach it; never over the gear or a control. tvOS: top left.
    @ViewBuilder private var numbers: some View {
        #if os(iOS)
        GeometryReader { geo in
            let i = geo.safeAreaInsets
            let g = TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height),
                                  insets: TouchInsets(top: i.top, left: i.leading, bottom: i.bottom, right: i.trailing))
            let f = TouchPanel.frame(width: Double(panelSize.width), height: Double(panelSize.height), geometry: g, controlsShown: !controllerPresent)
            numbersPanel
                .position(x: f.x + f.width / 2, y: f.y + f.height / 2)
                .opacity(panelSize == .zero ? 0 : 1)  // the first layout has no size yet
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        #else
        topLeft(numbersPanel)
        #endif
    }

    private var numbersPanel: NumbersPanel {
        NumbersPanel(lines: Strings.panelLines(level: model.settings.statsLevel, stats: model.playStats, pacing: model.settings.picturePacing,
                                               note: model.panelNote),
                     full: model.settings.statsLevel == .full, onSize: { size in if size != panelSize { panelSize = size } })
    }

    private func topLeft(_ panel: NumbersPanel) -> some View {
        panel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
    }

    private func closeMenu() { menu = false }

    /// Apple TV: the open menu panel would cover the numbers panel's long lines; it is hidden while the menu is open.
    private var numbersUnderMenu: Bool {
        #if os(tvOS)
        menu
        #else
        false
        #endif
    }

    private var menu: Bool {
        get { overlays.menu }
        nonmutating set { overlays.menu = newValue }
    }
    private var gamePage: Bool {
        get { overlays.sheet }
        nonmutating set { overlays.sheet = newValue }
    }
    /// Anything over the picture: the one rule (`PlayRoute.covered`) for neutral input, touch and the Apple TV route.
    private var covered: Bool { overlays.covers(trouble: model.trouble, startingCard: model.startingCard) }

    #if os(tvOS)

    /// The Siri Remote's Menu and Play/Pause (`PlayHost`); Menu where the menu may not open is "Back to games".
    private func remotePress(_ press: RemoteMenuRule.Press) {
        switch remote.press(press, menuOpen: menu, allowed: model.menuAllowed, at: ProcessInfo.processInfo.systemUptime) {
        case .open: menu = true
        case .close: menu = false
        case .leave: Task { await model.leave() }
        case .ignore: break
        }
    }
    #endif

    private var touchLayoutBinding: Binding<TouchLayout>? {
        #if os(iOS)
        Strings.showsTouchLayoutRow(gameControllers: controllerPresent ? 1 : 0) ? layoutChoice : nil
        #else
        nil
        #endif
    }

    #if os(iOS)
    /// The gear: opens the in-play menu (never over the ended card or the "reconnecting" screen).
    private func openMenu() { if !menu, model.menuAllowed { menu = true } }

    private var touchStore: TouchLayoutStore { TouchLayoutStore(fallback: model.settings.touchLayoutDefault) }
    private var titleID: String { model.gameState?.titleID ?? "" }

    /// The menu's "Touch layout" row: saved for this game, applied at once.
    private var layoutChoice: Binding<TouchLayout> {
        Binding(get: { touchLayout }, set: { l in
            touchLayout = l
            touchStore.set(l, for: titleID)
            parts.touch.setLayout(l)
        })
    }

    private var touchBlockers: TouchBlockers {
        TouchBlockers.reasons(menu: menu, sceneActive: scenePhase == .active, coverShown: covered,
                              controllerPresent: controllerPresent)
    }

    private func showControllerNote() {
        noteCount += 1
        let mine = noteCount
        controllerNote = true
        UIAccessibility.post(notification: .announcement, argument: Strings.controllerConnected)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if noteCount == mine { controllerNote = false }
        }
    }
    #endif

    /// A chord or Home: a sheet over play closes (only it); else the menu opens or closes, but never opens over the ended card
    /// or the "reconnecting" screen (`model.menuAllowed`).
    private func toggleMenu() { overlays.toggle(allowed: model.menuAllowed) }

    private func appear() {
        let controller = self.controller
        picture.controller = controller
        controller.onMenuChord = { toggleMenu() }
        controller.onMenuToggle = { toggleMenu() }
        #if os(tvOS)
        controller.onBack = {
            // B over a card (no menu) is the system's Menu press, "Back to games": only a B that closes the menu or the sheet is
            // the rule's own
            guard menu || gamePage else { return }
            let closesMenu = !gamePage
            overlays.back()
            if closesMenu { remote.controllerBack(at: ProcessInfo.processInfo.systemUptime) }  // the system's Menu press for this B is the same press
        }
        #else
        controller.onBack = { overlays.back() }
        #endif
        controller.menuOpen = covered
        #if os(tvOS)
        controller.presenceChanged = { on in
            #if DEBUG
            if Automation.keepsControls { return }  // screenshots: "Connect a controller" although the simulator reports one
            #endif
            controllerPresent = on
        }
        #endif
        #if os(iOS)
        let touch = parts.touch
        touchLayout = touchStore.layout(for: titleID)
        #if DEBUG
        if let l = Automation.touchLayout { touchLayout = l }  // this run only, not saved
        #endif
        touch.setLayout(touchLayout)
        touch.haptics = model.settings.touchHaptics
        touch.onOutput = { [weak controller] t in controller?.touchArrived(t) }
        touch.onGear = { openMenu() }
        controller.presenceChanged = { on in
            #if DEBUG
            if Automation.keepsControls { return }
            #endif
            controllerPresent = on
            if on { showControllerNote() }
        }
        #endif
        #if DEBUG
        #if os(iOS)
        if let after = Automation.gearAfter {  // screenshots: the gear's action runs this long after play begins
            Task { try? await Task.sleep(nanoseconds: UInt64(after * 1e9)); touch.performGear() }
        }
        #endif
        if let after = Automation.menuAfter {  // screenshots: the menu opens this long after play begins
            Task { try? await Task.sleep(nanoseconds: UInt64(after * 1e9)); menu = true }
        }
        // A scripted press must not be overwritten by the controller's own (neutral) state.
        if !Automation.drivesInput { controller.start() }
        #else
        controller.start()
        #endif
        // The Mac holds no input when play begins or a reconnect completes: a held button is sent again.
        controller.sendCurrent()
        model.onInputWanted = { [weak controller] in controller?.sendCurrent() }
        let view = picture
        view.startPacing(model: model)
        // Called on the decode task: hop to the main queue; the view shows it now or at the next refresh.
        model.onPicture = { [weak view] frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { view?.arrived(frame) } }
        }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = !model.reconnecting
        #endif
    }

    private func disappear() {
        model.onPicture = nil
        model.onInputWanted = nil
        controller.onMenuChord = nil
        controller.onMenuToggle = nil
        controller.onBack = nil
        controller.menuOpen = false
        #if os(tvOS)
        controller.presenceChanged = nil
        #endif
        #if os(iOS)
        controller.presenceChanged = nil
        parts.touch.releaseAll()  // the view's fingers are let go; `controller.stop()` then sends the neutral itself
        parts.touch.onOutput = nil
        parts.touch.onGear = nil
        #endif
        picture.stopPacing()
        controller.stop()
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
}
