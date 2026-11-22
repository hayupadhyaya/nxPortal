#if os(tvOS)
import PortalPlayer
import SwiftUI

/// Apple TV's shell over the same model (`§ screen-library`, `§ screen-macs`): the tab bar (Games, Macs, Settings) and the Mac's
/// name at the top left. Failures land on the library with the Mac unreachable, as everywhere (the model decides).
struct TVRootView: View {
    enum Tab: String, Hashable { case games, macs, settings }
    let model: ClientModel
    #if DEBUG
    @State private var tab: Tab = Automation.tvTab
    #else
    @State private var tab: Tab = .games
    #endif
    @State private var macsOverlaid = false
    private var p: LookPalette { Theme.palette }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                LibraryView(model: model, onMacs: nil, onSettings: nil, overlaid: tab != .games)
            }
            .tabItem { Text(Strings.gamesTitle) }
            .tag(Tab.games)

            MacListView(model: model, overlaid: $macsOverlaid)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
                .background(Theme.color(p.background).ignoresSafeArea())
                .tabItem { Text(Strings.macsTitle) }
                .tag(Tab.macs)

            SettingsView(model: model)
                .tabItem { Text(Strings.settings) }
                .tag(Tab.settings)
        }
        .overlay(alignment: .topLeading) { macName }
        // a Mac chosen on the Macs tab brings the person to its games (the iPhone sheet closes the same way)
        .onChange(of: model.macRows.first(where: \.current)?.id) { _, _ in if tab == .macs { tab = .games } }
        .tint(Theme.color(p.accentText))
    }

    /// The current Mac, top left, level with the tab bar.
    private var macName: some View {
        Label(model.hostName ?? Strings.gamesTitle, systemImage: "desktopcomputer")
            .font(.headline).lineLimit(1)
            .foregroundStyle(Theme.color(p.text))
            .padding(.leading, 90).padding(.top, 40)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
