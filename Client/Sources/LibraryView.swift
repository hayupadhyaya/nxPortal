import PortalKit
import PortalPlayer
import SwiftUI

/// The games on the current Mac (`§ screen-library`, B "Grid"): the Continue card, then every game as a tile, lit by the
/// Continue game's icon (Apple TV: the focused tile's). Not connected: the last known games, greyed, under the banner.
struct LibraryView: View {
    let model: ClientModel
    /// iPhone and tvOS: the Mac button; the gear. Nil on the iPad (the sidebar has them).
    let onMacs: (() -> Void)?
    let onSettings: (() -> Void)?
    /// A sheet (Macs, Settings) is open over the library; the pairing sheet shows through `model.screen`.
    var overlaid = false
    #if DEBUG
    @State private var page: String? = Automation.gamePage  // screenshots of a game's page
    #else
    @State private var page: String?
    #endif
    @FocusState private var focusedTile: String?
    /// The tile that last had focus: the Games tab on Apple TV gives it back when the person returns to the tab.
    @State private var lastFocused: String?
    /// A controller's Y on the focused tile opens its page (the rule is `LibraryPad`).
    @State private var pad = LibraryPad()
    private var p: LookPalette { Theme.palette }
    private var m: LibraryMetrics { .current }
    private var ready: Bool { model.macState == .connected }
    private var phone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: phone ? 14 : 22) {
                #if os(tvOS)
                HStack {
                    Spacer()
                    // the glass is the text's ground over any icon's glow (tested); the system toolbar button is not
                    Button { Task { await model.refresh() } } label: {
                        Text(Strings.refresh).font(.headline).padding(.horizontal, 28).frame(minHeight: Theme.buttonHeight)
                    }
                    .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                        .disabled(!ready)
                        .padding(6).glass(.thick, radius: 44)
                }
                #else
                if !phone {
                    // Refresh sits in the content, inside the safe area: the shell hides the system bar, so a bar item
                    // would be drawn under the status bar
                    HStack {
                        Text(Strings.gameCount(model.games.count)).font(.subheadline)
                            .foregroundStyle(Theme.color(p.text))  // Primary: Secondary fails over a white icon's glow (tested)
                        Spacer()
                        Button { Task { await model.refresh() } } label: {
                            Text(Strings.refresh).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
                        }
                        .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                        .disabled(!ready)
                    }
                }
                #endif
                banner
                #if os(tvOS)
                HStack(alignment: .top, spacing: 60) {
                    if let game = model.continueGame { card(game).frame(maxWidth: 1000).layoutPriority(1) }
                    focusCaption
                }
                #else
                if let game = model.continueGame { card(game) }
                #endif
                if !model.games.isEmpty {
                    Text(Strings.allGames).font(.title3.bold()).accessibilityAddTraits(.isHeader).padding(.top, 4)
                    grid
                } else if model.libraryLoading {
                    Text(Strings.libraryLoading).font(.body).foregroundStyle(Theme.color(p.secondaryText))
                } else if model.libraryCouldNotLoad {
                    Text(Strings.libraryCouldNotLoad(mac: model.hostName ?? Messages.theMac)).font(.body)
                        .foregroundStyle(Theme.color(p.secondaryText))
                    Button { Task { await model.refresh() } } label: {
                        Text(Strings.retry).font(.headline).padding(.horizontal, 20).frame(minHeight: 44)
                    }
                    .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                    .disabled(model.busy)
                } else if ready {
                    Text(Strings.emptyLibrary(mac: model.hostName ?? Messages.theMac)).font(.body)
                        .foregroundStyle(Theme.color(p.secondaryText))
                }
            }
            .padding(.horizontal, m.margin)
            .padding(.bottom, m.margin)
            .foregroundStyle(Theme.color(p.text))
        }
        .background { ambient }
        #if os(tvOS)
        .navigationTitle("")  // the Mac's name is at the top left of the shell (`TVRootView`)
        #else
        .navigationTitle(model.hostName ?? Strings.gamesTitle)
        #endif
        #if os(iOS)
        .refreshable { await model.refresh() }  // pull to refresh (iPhone; the iPad has the button in the "N games" row too)
        #endif
        .navigationDestination(item: $page) { GamePage(model: model, titleID: $0) }
        .toolbar { toolbar }
        .onAppear {
            restoreFocus()
            pad.onOptions = { title in if let game = model.optionsTarget(focused: title), page == nil { page = game } }
            pad.start()
        }
        .onDisappear { pad.stop(); pad.onOptions = nil }  // the closure holds this view's state: no cycle outlives it
        // Y acts on a tile the focus engine really holds, never on a remembered one.
        .onChange(of: focusedTile) { _, now in
            pad.focused = now
            if let now { lastFocused = now }
        }
        .onChange(of: frontmost, initial: true) { _, now in pad.frontmost = now }
        .onChange(of: model.screen) { _, now in if now == .library { restoreFocus(afterPlay: true) } }
    }

    /// The library is the frontmost thing: no sheet, game page or game over it.
    private var frontmost: Bool { !overlaid && page == nil && model.screen == .library }

    /// Apple TV: focus returns to the tile last played. Elsewhere nothing is focused until the focus engine says so.
    private func restoreFocus(afterPlay: Bool = false) {
        #if os(tvOS)
        focusedTile = afterPlay ? model.lastPlayedTile : (lastFocused ?? model.lastPlayedTile)
        #if DEBUG
        if let id = Automation.focusTile {  // screenshots: the simulator has no remote to move focus; the tile exists once the list is here
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); focusedTile = id }
        }
        #endif
        #endif
    }

    // MARK: pieces

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let onMacs {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: onMacs) { Label(Strings.macsButton(model.hostName), systemImage: "desktopcomputer") }
            }
        }
        if let onSettings {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onSettings) { Label(Strings.settings, systemImage: "gearshape") }
            }
        }
    }

    /// The Continue game's icon (Apple TV: the focused tile's), per `§ look-glow`; no icon: plain Background.
    private var ambient: some View {
        #if os(tvOS)
        let lit = model.games.first { $0.titleID == focusedTile } ?? model.continueGame
        return AmbientBackground(art: lit.flatMap { model.art(for: $0) }, side: 1300, opacity: 0.70,
                                 shade: .vertical([(0, 0), (0.45, 0.35), (1, 0.90)]), blur: 140)
        #else
        let art = model.continueGame.flatMap { model.art(for: $0) }
        return phone
            ? AmbientBackground(art: art, side: 640, opacity: 0.30, shade: .vertical([(0, 0), (0.7, 0.85)]), blur: 90)
            : AmbientBackground(art: art, side: 900, opacity: 0.38, shade: .vertical([(0, 0), (0.6, 0.80)]), blur: 120)
        #endif
    }

    #if os(tvOS)
    /// The tile that has focus, large beside the Continue card: its name, its state and how to open its options. Every line is
    /// the Primary text, on thick glass: over a white icon's glow no text colour holds without a ground (tested).
    @ViewBuilder private var focusCaption: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let game = model.games.first(where: { $0.titleID == focusedTile }) {
                let state = LibraryText.tileState(game, reachable: ready, preparing: model.preparing(for: game.titleID))
                Text(Strings.focusedLabel).font(.small.weight(.semibold)).foregroundStyle(Theme.color(p.tileCaption))
                Text(game.name).font(.largeTitle.bold()).lineLimit(2).foregroundStyle(Theme.color(p.text))
                if let line = Strings.focusState(state, lastPlayed: game.titleID == model.lastPlayedTitle) {
                    Text(line).font(.subheadline).foregroundStyle(Theme.color(p.tileCaption))
                }
                Text(Strings.focusHint).font(.small).foregroundStyle(Theme.color(p.tileCaption))
            }
        }
        .padding(24)
        .glass(.thick, radius: Theme.radii.group)
        .opacity(model.games.contains { $0.titleID == focusedTile } ? 1 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)  // the tile itself speaks its name, state and hint
    }
    #endif

    @ViewBuilder private var banner: some View {
        if model.macState == .unreachable {
            let text = Messages.banner(model.problem ?? .cannotReach, mac: model.hostName ?? Messages.theMac,
                                       discoveryBlocked: model.discoveryMessage != nil)
            ConnectionBanner(text: text, busy: model.busy) {
                Task { await model.retry() }
            }
        } else if let text = model.message {
            Text(text).font(.subheadline).foregroundStyle(Theme.color(p.text))
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .glass(.thick, radius: Theme.radii.banner)
        }
    }

    private func card(_ game: GameEntry) -> some View {
        ContinueCard(game: game, art: model.art(for: game), palette: model.palette(for: game), iconSide: m.card,
                     enabled: ready && game.streamable, preparing: ready ? model.preparing(for: game.titleID) : nil,
                     playsHere: model.playChosen,
                     onResume: { Task { await play(game) } }, onOptions: { page = game.titleID },
                     onQuit: game.state == .idle ? nil : { Task { await model.quitGame() } })
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: m.cell), spacing: m.across, alignment: .top)], alignment: .leading,
                  spacing: m.down) {
            ForEach(model.games, id: \.titleID) { game in
                let state = LibraryText.tileState(game, reachable: ready, preparing: model.preparing(for: game.titleID))
                GameTile(game: game, art: model.art(for: game), state: state, side: m.icon, focus: $focusedTile,
                         onPlay: { Task { await play(game) } }, onOptions: { page = game.titleID },
                         onQuit: game.state == .idle ? nil : { Task { await model.quitGame() } })
            }
        }
        .padding(.vertical, 8)
    }

    /// A paused or running game resumes; any other starts.
    private func play(_ game: GameEntry) async {
        if game.state == .idle { await model.launch(game) } else { await model.resume() }
    }
}
