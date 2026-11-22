#if os(iOS)
import PortalPlayer
import SwiftUI

/// The library with the Macs next to it: a sidebar on a regular-width iPad, a sheet from the title button on iPhone
/// (Apple TV has `TVRootView`) -> `§ screen-macs`
struct LibraryShell: View {
    let model: ClientModel
    #if DEBUG
    @State private var showMacs = CommandLine.arguments.contains("-autoShowMacs")  // screenshots of the iPhone Macs sheet
    #else
    @State private var showMacs = false
    #endif
    #if DEBUG
    @State private var showSettings = Automation.showsSettings  // screenshots of Settings
    #else
    @State private var showSettings = false
    #endif
    @State private var sidebarOverlaid = false
    /// A Mac chosen for pairing in the Macs sheet: paired once the sheet has gone (the pairing sheet is the root's).
    @State private var pairAfterMacs: MacRow?
    @Environment(\.horizontalSizeClass) private var width
    private var p: LookPalette { Theme.palette }

    var body: some View {
        content
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
    }

    @ViewBuilder private var content: some View {
        if width == .regular { split } else { stack }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gamecontroller.fill").accessibilityHidden(true)
                    Text("nxPortal").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape").padding(6) }
                        .buttonStyle(.portal(.button)).accessibilityLabel(Strings.settings)
                }
                .padding(.horizontal, 16).padding(.top, 12)
                MacListView(model: model, overlaid: $sidebarOverlaid)
            }
            .foregroundStyle(Theme.color(p.text))
            .background(Theme.color(p.groupedSurface).ignoresSafeArea())
            .navigationSplitViewColumnWidth(300)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            NavigationStack { LibraryView(model: model, onMacs: nil, onSettings: nil, overlaid: showSettings || sidebarOverlaid) }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.color(p.accentText))
    }

    private var stack: some View {
        NavigationStack {
            LibraryView(model: model, onMacs: { showMacs = true }, onSettings: { showSettings = true },
                        overlaid: showMacs || showSettings)
        }
        .sheet(isPresented: $showMacs, onDismiss: {
            guard let row = pairAfterMacs else { return }
            pairAfterMacs = nil
            Task { await model.switchMac(row) }
        }) {
            NavigationStack {
                MacListView(model: model, onDone: { showMacs = false },
                            onPair: { row in pairAfterMacs = row; showMacs = false }, overlaid: .constant(false))
                    .background(Theme.color(p.groupedSurface).ignoresSafeArea())
                    .navigationTitle(Strings.macsTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(Strings.done) { showMacs = false } } }
            }
        }
    }
}
#endif
