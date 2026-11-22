import PortalKit
import PortalPlayer
import SwiftUI
import UIKit

/// What the play screen says when the picture stops arriving: a pill, a "reconnecting" over the blurred picture, an ended
/// card. The picture's blur and dimming are the stage's (`TroubleStage.pictureBlur` / `pictureBrightness`), applied by `PlayView`.
/// -> `§ screen-errors`
struct TroubleView: View {
    let model: ClientModel
    @FocusState private var reconnectFocused: Bool
    /// Apple TV: the reconnecting card's one button takes focus when the card appears (the controller reaches it, `PlayRoute`).
    @FocusState private var stopFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var p: LookPalette { Theme.palette }

    private var mac: String { model.hostName ?? Messages.theMac }
    private var game: GameEntry? { model.games.first { $0.titleID == model.gameState?.titleID } }
    private var gameName: String { game?.name ?? Messages.theGame }

    private var column: CGFloat {
        #if os(tvOS)
        800
        #else
        420
        #endif
    }

    /// Apple TV: room between the two 76 pt buttons and under them for the focused one's lift, inside the card.
    private var buttonGap: CGFloat {
        #if os(tvOS)
        32
        #else
        10
        #endif
    }

    /// A card centred while it fits; scrolling when it does not (large text, a short landscape phone): its exit stays reachable.
    private func fitting<Card: View>(_ card: Card) -> some View {
        GeometryReader { geo in
            ScrollView {
                card.frame(maxWidth: .infinity, minHeight: geo.size.height)  // centred while it is shorter than the screen
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    var body: some View {
        ZStack {
            switch model.trouble {
            case .none: EmptyView()
            case .pill: pill
            case .reconnecting: fitting(reconnecting)
            case let .ended(reason): fitting(ended(reason))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.motion.menu), value: model.trouble)
        .onChange(of: model.trouble) { _, stage in
            // VoiceOver hears each step once as it appears.
            switch stage {
            case .none: break
            case .pill: UIAccessibility.post(notification: .announcement, argument: Strings.reconnecting)
            case .reconnecting: UIAccessibility.post(notification: .announcement, argument: Strings.reconnectingTitle(mac: mac))
            case let .ended(reason): UIAccessibility.post(notification: .announcement, argument: reason)
            }
        }
    }

    /// Thick glass, 36 tall, the Warning Wi-Fi glyph; 66 pt from the top, centred; never takes a touch.
    private var pill: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.color(p.warning)).accessibilityHidden(true)
                Text(Strings.reconnecting).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.color(p.text))
            }
            .padding(.horizontal, 16).frame(height: 36)
            .glass(.thick, radius: 18)
            .padding(.top, 66)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var reconnecting: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(Theme.color(LookTokens.troubleText))
            Text(Strings.reconnectingTitle(mac: mac)).font(.title3.weight(.semibold))
            Text(Strings.reconnectingBody(game: gameName)).font(.subheadline)
            Button { Task { await model.leave() } } label: {
                Text(Strings.stopAndGoToGames).font(.headline).padding(.horizontal, 20).frame(minHeight: Theme.buttonHeight)
            }
            .buttonStyle(.portal(.button, fill: p.fill2, text: LookTokens.troubleText))
            .focused($stopFocused)
            .padding(.top, 8)
        }
        #if os(tvOS)
        .onAppear { stopFocused = true }
        #endif
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.color(LookTokens.troubleText))  // over the dimmed picture and the scrim (tested)
        .padding(24)
        .frame(maxWidth: column)
    }

    private func ended(_ reason: String) -> some View {
        VStack(spacing: 14) {
            if let game { GameIcon(name: game.name, art: model.art(for: game), side: 56) }
            Text(Strings.sessionEndedTitle).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(reason).font(.subheadline)
            VStack(spacing: buttonGap) {
                Button { Task { await model.leave() } } label: {
                    Text(Strings.backToGames).font(.headline).padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
                }
                .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                Button { Task { await model.reconnectNow() } } label: {
                    Label(Strings.reconnect, systemImage: "arrow.clockwise").font(.headline).padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
                }
                .buttonStyle(.portal(.button, fill: p.accentFill, text: p.onAccent))
                .focused($reconnectFocused)
                .disabled(model.busy)
            }
            .padding(.top, 4)
            #if os(tvOS)
            .padding(.vertical, 12)
            #endif
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.color(p.text))  // over glass
        .padding(24)
        .frame(maxWidth: column)
        .glass(.thick, radius: Theme.radii.card)
        .padding(24)
        .defaultFocus($reconnectFocused, true)
        .onAppear { reconnectFocused = true }
    }
}
