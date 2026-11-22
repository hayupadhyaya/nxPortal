import PortalKit
import PortalPlayer
import SwiftUI

/// Tile sizes per platform (`§ look-space`): icon side, cell width, gaps, screen margin.
@MainActor struct LibraryMetrics {
    let icon: CGFloat, cell: CGFloat, across: CGFloat, down: CGFloat, margin: CGFloat, card: CGFloat

    static var current: LibraryMetrics {
        #if os(tvOS)
        LibraryMetrics(icon: 230, cell: 250, across: 44, down: 44, margin: 90, card: 160)
        #else
        UIDevice.current.userInterfaceIdiom == .phone
            ? LibraryMetrics(icon: 68, cell: 84, across: 10, down: 14, margin: 20, card: 52)
            : LibraryMetrics(icon: 108, cell: 116, across: 20, down: 22, margin: 36, card: 96)
        #endif
    }
}

/// A game's icon at `side`: its art (decoded bounded off the main actor by `IconDecoder`), else a Slate square with its
/// initials; Slate until the decode is here, and never an older icon of the same game.
struct GameIcon: View {
    let name: String
    let art: Data?
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var decoded: (key: String, image: CGImage)?
    private var pixels: Int { Int(side * scale) }
    private var key: String? { art.map { "\(ArtKey($0))-\(pixels)" } }
    private var p: LookPalette { Theme.palette }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: side * Theme.radii.iconFraction, style: .continuous) }

    /// The image of THIS icon: the decoded one only when its key is the current one.
    private var image: CGImage? {
        guard let key else { return nil }
        if let decoded, decoded.key == key { return decoded.image }
        return Self.decoder.cached(key)
    }

    static let decoder = IconDecoder()

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.color(p.slateTop), Theme.color(p.slateBottom)], startPoint: .top, endPoint: .bottom)
                    Text(LibraryText.initials(name)).font(.system(size: side * 0.3, weight: .bold))
                        .foregroundStyle(Theme.color(p.initials))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .accessibilityHidden(true)
        // A cache miss decodes off the main actor; the task is cancelled when the tile goes away or its icon changes.
        .task(id: key) {
            guard let art, let key, Self.decoder.cached(key) == nil else { return }
            if let made = await Self.decoder.image(key: key, png: art, pixels: pixels) { decoded = (key, made) }
        }
    }
}

/// One game in the grid: the icon is the button, the name below it; greyed (saturation 0, opacity .42) for a rebuild or
/// an unreachable Mac. VoiceOver: one element, label the name, value its state, hint, actions Options and Quit game.
struct GameTile: View {
    let game: GameEntry
    let art: Data?
    let state: LibraryText.TileState
    let side: CGFloat
    var focus: FocusState<String?>.Binding?
    let onPlay: () -> Void
    let onOptions: () -> Void
    var onQuit: (() -> Void)?
    private var p: LookPalette { Theme.palette }
    private var greyed: Bool { state == .rebuild || state == .unreachable }
    /// The percent of a preparing game (nil: preparing with no number).
    private var preparingPercent: Int? { if case let .preparing(percent) = state { percent } else { nil } }
    private var isPreparing: Bool { if case .preparing = state { true } else { false } }

    var body: some View {
        VStack(spacing: 4) {
            PortalTile(name: game.name, side: side, dimmed: greyed, focusKey: game.titleID, focus: focus, action: onPlay) {
                GameIcon(name: game.name, art: art, side: side)
                    .saturation(greyed ? 0 : 1).opacity(greyed ? 0.42 : 1)
                    .overlay { if isPreparing { PreparingRing(percent: preparingPercent, side: side) } }
            }
            if state == .rebuild || state == .paused || isPreparing {
                Text(state == .rebuild ? Strings.rebuildNeeded
                        : isPreparing ? Strings.tileCaption(percent: preparingPercent) : Strings.tileValue(.paused))
                    .font(.tiny).lineLimit(1)
                    .foregroundStyle(Theme.color(p.tileCaption))
            }
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onOptions() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
        .accessibilityValue(Strings.tileValue(state))
        .accessibilityHint(greyed ? "" : Strings.tileHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !greyed { onPlay() } }
        .accessibilityAction(named: Strings.options) { onOptions() }
        .modifier(QuitAction(onQuit: onQuit))
    }
}

private struct QuitAction: ViewModifier {
    let onQuit: (() -> Void)?
    func body(content: Content) -> some View {
        if let onQuit { content.accessibilityAction(named: Strings.quitGame) { onQuit() } } else { content }
    }
}

/// A game that is preparing: its icon under a scrim, a light ring over it (an arc for the percent; a quarter turning
/// without one, still under Reduce Motion). A graphic, 3:1 over any icon (tested).
struct PreparingRing: View {
    let percent: Int?
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    private var p: LookPalette { Theme.palette }
    private var fraction: Double { percent.map { Double($0) / 100 } ?? 0.25 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * Theme.radii.iconFraction, style: .continuous).fill(Theme.color(p.scrim))
            Circle().stroke(Theme.color(p.text).opacity(0.3), lineWidth: max(3, side * 0.04)).frame(width: side * 0.46)
            Circle().trim(from: 0, to: fraction)
                .stroke(Theme.color(p.text), style: StrokeStyle(lineWidth: max(3, side * 0.04), lineCap: .round))
                .frame(width: side * 0.46)
                .rotationEffect(.degrees(-90 + (percent == nil && turning && !reduceMotion ? 360 : 0)))
        }
        .allowsHitTesting(false)
        .onAppear {
            if percent == nil, !reduceMotion { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true } }
        }
    }
}
