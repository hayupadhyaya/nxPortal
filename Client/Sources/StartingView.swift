import PortalKit
import PortalPlayer
import SwiftUI
import UIKit

/// While the game prepares its graphics (or the Mac has said nothing for a while): the game over its own glow, on one glass
/// card. Progress with a count and the time so far, or "Waiting for the game" with a clock. Leaving does not stop it.
/// -> `§ screen-starting`
struct StartingView: View {
    let model: ClientModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var announcer = PreparingText.Announcer()
    private var p: LookPalette { Theme.palette }

    private var game: GameEntry? { model.games.first { $0.titleID == model.gameState?.titleID } }
    private var mac: String { model.hostName ?? Messages.theMac }
    private var display: PreparingText.Display { PreparingText.display(model.preparing ?? .waiting) }
    private var percent: Int? { if case let .progress(q) = display { q.percent } else { nil } }

    private var column: CGFloat {
        #if os(tvOS)
        900
        #else
        480
        #endif
    }
    private var iconSide: CGFloat {
        #if os(tvOS)
        150
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? 84 : 110
        #endif
    }

    var body: some View {
        ZStack {
            AmbientBackground(art: game.flatMap { model.art(for: $0) }, side: 700, opacity: 0.70,
                              shade: .radial([(0, 0.15), (1, 0.8)]), blur: 100, placement: .center)
            ScrollView {
                VStack(spacing: 16) {
                    Text(PreparingText.header(game: game?.name ?? Messages.theGame, mac: mac)).font(.subheadline).foregroundStyle(Theme.color(p.secondaryText))
                    if let game { GameIcon(name: game.name, art: model.art(for: game), side: iconSide) }
                    switch display {
                    case let .progress(q): preparing(q)
                    case .waiting: waiting
                    }
                    actions
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.color(p.text))  // over glass over the glow: full-opacity Text -> look-access
                .padding(28)
                .frame(maxWidth: column)
                .glass(.thick, radius: Theme.radii.card)
                .padding(LibraryMetrics.current.margin)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear { _ = announcer.next(percent) }  // seeds the first percent: onChange never fires for it
        .onChange(of: percent) { _, new in
            // Said at 25, 50 and 75 percent, also when progress resumes after a "waiting" gap.
            if let text = announcer.next(new) { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }

    private func preparing(_ q: Preparing) -> some View {
        VStack(spacing: 12) {
            Text(PreparingText.preparingTitle).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text(PreparingText.firstStartNote).font(.subheadline)
            bar(q.fraction)
            HStack {
                Text(PreparingText.count(q)).monospacedDigit()
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(PreparingText.elapsed(context.date.timeIntervalSince(model.preparingSince ?? context.date))).monospacedDigit()
                }
            }
            .font(.small)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PreparingText.preparingTitle)
        .accessibilityValue(PreparingText.accessibilityValue(q))
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(Theme.color(p.text))
            Text(PreparingText.waitingTitle).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(PreparingText.clock(context.date.timeIntervalSince(model.preparingSince ?? context.date)))
                    .font(.title2).monospacedDigit()
            }
            Text(PreparingText.waitingBody(game: game?.name ?? Messages.theGame, mac: mac)).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { Task { await model.leave() } } label: {
                    Text(Strings.backToGames).font(.headline).padding(.horizontal, 20).frame(minHeight: Theme.buttonHeight)
                }
                .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                if case .waiting = display {
                    Button { Task { await model.quitGame() } } label: {
                        Text(Strings.quitGame).font(.headline).padding(.horizontal, 20).frame(minHeight: Theme.buttonHeight)
                    }
                    .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                }
            }
            if case .progress = display { Text(PreparingText.leaveNote).font(.small) }
        }
    }

    /// The game's Vivid gradient on the fill track.
    private func bar(_ fraction: Double) -> some View {
        let palette = game.map { model.palette(for: $0) } ?? .slate
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.color(p.fill2))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.color(palette.vivid), Theme.color(palette.progressEnd)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 8)
    }
}
