import PortalKit
import PortalPlayer
import SwiftUI

/// A game's page (`§ screen-game-page`): on the left its icon over its own glow, name, where and how it is, Play and ⋯
/// (Quit game while it runs); on the right its own options (`OptionsColumn`), which scrolls on its own.
/// `onPlay`: opened over play (the in-play menu's "All game options"), Play closes the page instead of starting anything.
struct GamePage: View {
    let model: ClientModel
    let titleID: String
    var onPlay: (() -> Void)?
    private var p: LookPalette { Theme.palette }
    private var game: GameEntry? { model.games.first { $0.titleID == titleID } }
    private var ready: Bool { model.macState == .connected }

    private var iconSide: CGFloat {
        #if os(tvOS)
        300
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? 96 : 196
        #endif
    }

    var body: some View {
        Group {
            if let game { page(game) } else { Color.clear }
        }
        .background {
            AmbientBackground(art: game.flatMap { model.art(for: $0) }, side: 700, opacity: 0.70,
                              shade: .horizontal([(0, 0), (0.52, 1)]), blur: 100, placement: .leftThird)
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var idiom: OptionLayout.Idiom {
        #if os(tvOS)
        .tv
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? .phone : .tablet
        #endif
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Two columns where both fit (`OptionLayout.pageColumns`): the game on the left with Play always in view, the options
    /// on the right scrolling on their own; one scrolling column at the largest text size or on a narrow screen.
    private func page(_ game: GameEntry) -> some View {
        GeometryReader { geo in
            switch OptionLayout.pageColumns(width: Double(geo.size.width), idiom: idiom, accessibilitySize: typeSize.isAccessibilitySize) {
            case let .two(left):
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView { info(game).frame(maxWidth: .infinity, alignment: .leading) }
                        actions(game)
                    }
                    .padding(LibraryMetrics.current.margin)
                    .frame(width: CGFloat(left))
                    ScrollView {
                        OptionsColumn(model: model, titleID: titleID)
                            .padding(LibraryMetrics.current.margin)
                            .frame(maxWidth: 720, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .single:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        info(game)
                        actions(game)
                        OptionsColumn(model: model, titleID: titleID)
                    }
                    .padding(LibraryMetrics.current.margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(Theme.color(p.text))  // over the shade, full-opacity Text -> look-access
    }

    private func info(_ game: GameEntry) -> some View {
        let state = LibraryText.tileState(game, reachable: ready, preparing: model.preparing(for: game.titleID))
        return VStack(alignment: .leading, spacing: 12) {
            GameIcon(name: game.name, art: model.art(for: game), side: iconSide)
            Text(game.name).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text([Strings.onMac(model.hostName ?? Messages.theMac), Strings.tileValue(state)].filter { !$0.isEmpty }
                    .joined(separator: " · "))
                .font(.subheadline)
            if model.showsSizeLine(for: titleID) {
                Text(Strings.streamSizeLine(model.streamSizeLine(for: titleID))).font(.small)
            }
            if let hint = Strings.sizeHint(model.options(for: titleID)) { Text(hint).font(.small) }
        }
    }

    private func actions(_ game: GameEntry) -> some View {
        let running = game.state == .running || game.state == .paused
        return HStack(spacing: 14) {
            Button { Task { await play(game) } } label: {
                Label(running ? Strings.continueAction(game) : Strings.play, systemImage: "play.fill").font(.headline)
                    .padding(.horizontal, 20).frame(minHeight: 44)
            }
            .buttonStyle(.portal(.button, fill: p.accentFill, text: p.onAccent))
            .disabled(!ready || !game.streamable)
            .opacity(ready && game.streamable ? 1 : 0.42)
            if running {
                Menu {
                    Button(Strings.quitGame, role: .destructive) { Task { await model.quitGame() } }
                } label: {
                    Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
                }
                .menuStyle(.button)
                .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                .accessibilityLabel(Strings.more)
            }
        }
    }

    private func play(_ game: GameEntry) async {
        if let onPlay { return onPlay() }
        if game.state == .idle { await model.launch(game) } else { await model.resume() }
    }
}
