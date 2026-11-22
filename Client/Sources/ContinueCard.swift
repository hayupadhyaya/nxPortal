import PortalKit
import PortalPlayer
import SwiftUI

/// The Continue card (`§ screen-library`): the running or paused game, else the last played; glass tinted by the icon's
/// Vivid and Deep. VoiceOver: the card is one element, its Resume / Play button another.
struct ContinueCard: View {
    let game: GameEntry
    let art: Data?
    let palette: ArtPalette
    let iconSide: CGFloat
    let enabled: Bool
    /// The Mac's live preparation of this game (a live library); nil otherwise.
    var preparing: Preparing? = nil
    /// This device's session plays the game (else a running game is one whose pause is owed).
    var playsHere = true
    let onResume: () -> Void
    let onOptions: () -> Void
    let onQuit: (() -> Void)?
    private var p: LookPalette { Theme.palette }
    private var phone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    private var radius: CGFloat {
        #if os(tvOS)
        Theme.radii.cardTV
        #else
        phone ? Theme.radii.cardPhone : Theme.radii.card
        #endif
    }

    var body: some View {
        HStack(spacing: phone ? 14 : 22) {
            HStack(spacing: phone ? 14 : 22) {
                GameIcon(name: game.name, art: art, side: iconSide)
                if phone {
                    Text("\(Strings.continueTitle) · \(game.name) · \(Strings.continueState(game, preparing: preparing, playsHere: playsHere))")
                        .font(.headline).lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.continueTitle).font(.small.weight(.semibold))
                        Text(game.name).font(.title2.bold()).lineLimit(2)
                        Text(Strings.continueState(game, preparing: preparing, playsHere: playsHere)).font(.subheadline)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.continueLabel(game, preparing: preparing, playsHere: playsHere))
            Spacer(minLength: 12)
            Button(action: onResume) {
                Label(Strings.continueAction(game), systemImage: "play.fill").font(.headline)
                    .padding(.horizontal, 20).frame(minHeight: phone ? 34 : 44)
            }
            .buttonStyle(.portal(.button, fill: p.accentFill, text: p.onAccent))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.42)
            Menu {
                Button(Strings.options, action: onOptions)
                if let onQuit { Button(Strings.quitGame, role: .destructive, action: onQuit) }
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: phone ? 34 : 44, height: phone ? 34 : 44)
            }
            .menuStyle(.button)
            .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
            .accessibilityLabel(Strings.more)
        }
        .foregroundStyle(Theme.color(p.text))  // Text on the tint at full opacity -> look-access
        .padding(phone ? 12 : 20)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(stops: [.init(color: Theme.color(palette.vivid).opacity(0.33), location: 0),
                                             .init(color: Theme.color(palette.deep).opacity(0.15), location: 0.55),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .glass(radius: radius)
    }
}
