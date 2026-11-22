import PortalKit
import PortalPlayer
import SwiftUI

/// The in-play menu (`§ screen-play`): over the dimmed picture, modal. Now (changes at once), Needs a new connection (the
/// game keeps going), Disconnect and Quit. Closes by its button, a tap outside, B or Home on a controller, Back on Apple TV;
/// no timer. Settings are saved at once; the ceiling and the numbers level go to the Host as they change.
struct PlayMenuView: View {
    let model: ClientModel
    let onClose: () -> Void
    /// iPhone and iPad: this game's on-screen layout (nil on Apple TV).
    var touchLayout: Binding<TouchLayout>?
    /// "All game options": the game's page over the play (nil: the row is not drawn).
    var onAllOptions: ((String) -> Void)?
    @AccessibilityFocusState private var titleFocused: Bool
    #if os(tvOS)
    /// Apple TV: focus starts on Disconnect (back to the games) when the menu opens.
    @FocusState private var startFocus: Bool
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var p: LookPalette { Theme.palette }
    private var phone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var idiom: OptionLayout.Idiom {
        #if os(tvOS)
        .tv
        #else
        phone ? .phone : .tablet
        #endif
    }

    /// The game has options to show under "Next start".
    private var hasOptions: Bool {
        guard let id = game?.titleID, model.optionsState(for: id) == .loaded else { return false }
        return !(model.options(for: id)?.settings.isEmpty ?? true)
    }

    private var game: GameEntry? {
        guard let id = model.gameState?.titleID else { return nil }
        return model.games.first { $0.titleID == id }
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.color(p.scrim).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            #if os(tvOS)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                panel($model).frame(width: 760).padding(60)
            }
            #else
            panel($model).padding(.horizontal, phone ? 62 : 90).padding(.vertical, phone ? 16 : 40)
            #endif
        }
        .onChange(of: model.settings) { _, new in SavedSettings.save(new) }
        .onChange(of: model.settings.bitrateMbps) { model.applyLive() }
        .onChange(of: model.settings.statsLevel) { model.applyLive() }
        .onAppear {
            titleFocused = true
            #if os(tvOS)
            startFocus = true
            #endif
        }
        .task(id: game?.titleID) { if let id = game?.titleID { await model.loadOptions(titleID: id) } }  // the phone's third page needs to know
    }

    #if DEBUG
    @State private var page = Automation.menuPage
    #else
    @State private var page = 0
    #endif

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Opaque, then clear over the last 28 pt of a column that scrolls.
    private var bottomFade: some View {
        VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
        }
    }

    private func pagePicker() -> some View {
        Picker(Strings.menuTitle, selection: $page) {
            let pages = OptionLayout.menuPages(idiom, hasOptions: hasOptions)
            ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                Text(OptionLayout.tabLabel(page, among: pages)).lineLimit(1).minimumScaleFactor(0.5).tag(i)
            }
        }
        .pickerStyle(.segmented)
    }

    private func panel(_ m: Bindable<ClientModel>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(tvOS)
            header
            ScrollView { VStack(alignment: .leading, spacing: 18) { now(m); newConnection(m); nextStart; leave }.padding(.bottom, 40) }  // focus scrolls it; the last row clears the panel's edge
            Text(Strings.closeHintTV).font(.small).foregroundStyle(Theme.color(p.secondaryText))
            #else
            if phone && typeSize.isAccessibilitySize {
                // large text on a short screen: one column that scrolls as a whole, the page choice at its top
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        pagePicker()
                        phonePage(m)
                        leave
                        Text(Strings.closeHint).font(.small).foregroundStyle(Theme.color(p.secondaryText))
                    }
                }
                .scrollIndicators(.visible)
            } else {
                header
                HStack(alignment: .top, spacing: 18) {
                    if phone {
                        // a short screen: the two groups are pages with their titles always in view (no hidden group)
                        VStack(alignment: .leading, spacing: 10) {
                            pagePicker()
                            ScrollView { phonePage(m) }.scrollIndicators(.visible)
                                .mask(alignment: .top) { bottomFade }  // "more below": the last visible row fades out
                        }
                    } else {
                        ScrollView { VStack(alignment: .leading, spacing: 18) { now(m); newConnection(m) } }
                    }
                    ScrollView { VStack(alignment: .leading, spacing: 18) { if OptionLayout.nextStart(idiom, accessibilitySize: typeSize.isAccessibilitySize) == .column { nextStart }; leave } }.scrollIndicators(.visible)
                }
                Text(Strings.closeHint).font(.small).foregroundStyle(Theme.color(p.secondaryText))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            #endif
        }
        .padding(phone ? 16 : 24)
        .foregroundStyle(Theme.color(p.text))
        .glass(.thick, radius: {
            #if os(tvOS)
            Theme.radii.menuTV
            #else
            Theme.radii.menu
            #endif
        }())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let game { GameIcon(name: game.name, art: model.art(for: game), side: phone ? 40 : 52) }
            VStack(alignment: .leading, spacing: 2) {
                Text(game?.name ?? Strings.menuTitle).font(.title2.bold()).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.color(p.secondaryText)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40)
            }
            .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
            .accessibilityLabel(Strings.closeMenu)
        }
    }

    private var subtitle: String {
        let s = model.playStats
        return Strings.menuSubtitle(mac: model.hostName, width: s?.width ?? 0, height: s?.height ?? 0, fps: Int((s?.macFps ?? 0).rounded()))
    }

    private func now(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.nowTitle, caption: Strings.nowCaption) {
            ChoiceRow(label: Strings.bitrate, note: Strings.bitrateNote, selection: m.settings.bitrateMbps,
                      choices: Choices.bitrateChoices(model.settings))
            SwitchRow(label: Strings.smoothPicture, note: Strings.smoothPictureNote, overPicture: true, isOn: m.settings.smooth)
            LevelRow(level: m.settings.statsLevel)
            if let touchLayout {
                ChoiceRow(label: Strings.touchLayoutTitle, note: Strings.touchLayoutNote, selection: touchLayout,
                          choices: Strings.touchLayoutChoices)
            }
        }
    }

    private func newConnection(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.newConnectionTitle, caption: Strings.newConnectionCaption) {
            ChoiceRow(label: Strings.streamSize, note: Strings.sizeNote(model.sizeNote(for: model.gameState?.titleID)),
                      selection: m.settings.size, choices: Choices.sizeChoices(model.settings),
                      disabled: Choices.sizesOff(model, for: model.gameState?.titleID))
            ChoiceRow(label: Strings.frameRate, selection: m.settings.maxFps, choices: Choices.rateChoices(model.settings))
            Button {
                onClose()
                Task { await model.reconnectApplying() }
            } label: {
                HStack(spacing: 8) {
                    Text(Strings.applyAndReconnect).font(.headline)
                    if model.pendingReconnect {
                        Circle().fill(Theme.color(p.warning)).frame(width: 8, height: 8).accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 20).frame(minHeight: 44)
            }
            .buttonStyle(.portal(.button, fill: model.pendingReconnect ? p.accentFill : p.fill2, text: model.pendingReconnect ? p.onAccent : p.text))
            .disabled(!model.pendingReconnect || model.busy)
            .accessibilityValue(model.pendingReconnect ? Strings.pendingChange : "")
            .padding(12)
        }
    }

    /// The phone's page: Now, Connection or Next start (a page that lost its options goes back to Now).
    @ViewBuilder private func phonePage(_ m: Bindable<ClientModel>) -> some View {
        switch page {
        case 1: newConnection(m)
        case 2 where hasOptions: nextStart
        default: now(m)
        }
    }

    /// "Next start of this game": the game's own options, a few rows (`§ screen-play`); nothing without a list.
    @ViewBuilder private var nextStart: some View {
        if let game {
            NextStartGroup(model: model, titleID: game.titleID, gameName: game.name) { onAllOptions?(game.titleID) }
        }
    }

    /// Apple TV: the labels never shrink under the television's text floor (they wrap instead); a phone may shrink them.
    #if os(tvOS)
    private static let leaveLines = 2, leaveScale: CGFloat = 1
    #else
    private static let leaveLines = 1, leaveScale: CGFloat = 0.6
    #endif

    private var leave: some View {
        VStack(alignment: .leading, spacing: 10) {
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))) {
                Button {
                    onClose()
                    Task { await model.leave() }
                } label: { Text(Strings.disconnect).font(.headline).lineLimit(Self.leaveLines).minimumScaleFactor(Self.leaveScale).padding(.horizontal, 20).frame(minHeight: Theme.buttonHeight) }
                    .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                    #if os(tvOS)
                    .focused($startFocus)
                    #endif
                Button {
                    onClose()
                    Task { await model.quitGame() }
                } label: { Text(Strings.quitGame).font(.headline).lineLimit(Self.leaveLines).minimumScaleFactor(Self.leaveScale).padding(.horizontal, 20).frame(minHeight: Theme.buttonHeight) }
                    .buttonStyle(.portal(.button, fill: p.fill, text: p.text))
                    .overlay(Capsule().strokeBorder(Theme.color(p.destructive), lineWidth: 1.5))  // the red is the ring: red text fails over a bright picture (tested)
            }
            Text(Strings.disconnectNote(preparing: model.preparing != nil)).font(.small).foregroundStyle(Theme.color(p.secondaryText))
        }
    }
}
