import PortalKit
import PortalPlayer
import SwiftUI
import UIKit

@main
struct NxPortalApp: App {
    @State private var model: ClientModel
    @Environment(\.scenePhase) private var phase
    #if os(iOS)
    @State private var work = BackgroundWork()
    #endif

    init() {
        let device = UIDevice.current
        #if os(tvOS)
        let kind = DeviceKind.tv
        #else
        let kind: DeviceKind = device.userInterfaceIdiom == .pad ? .tablet : .phone
        #endif
        #if DEBUG
        let secrets = Automation.secrets()
        #else
        let secrets: any SecretStoring = KeychainSecrets()
        #endif
        let model = ClientModel(store: ClientStore(secrets: secrets), browser: HostBrowser(),
                                kind: kind, settings: SavedSettings.load(),
                                recordingsDirectory: URL.documentsDirectory.appendingPathComponent("sessions"),
                                cache: LibraryCache(directory: URL.cachesDirectory.appendingPathComponent("libraries")),
                                artCache: ArtCache(directory: URL.cachesDirectory.appendingPathComponent("art")))
        model.start()
        _model = State(initialValue: model)
        #if DEBUG
        Automation.begin(model)
        #endif
    }

    /// The goodbye to the Mac must get out before the app is suspended (iOS gives a few seconds for it).
    private func background() {
        #if os(iOS)
        work.run { await model.background() }
        #else
        Task { await model.background() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)  // dark only in 1.0
                #if os(iOS)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)  // landscape heights hold no more (`§ look-access`); sheets inherit it
                #endif
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .background: background()
            case .active: Task { await model.foreground() }
            default: break
            }
        }
    }
}

/// The settings in `UserDefaults` (JSON): saved by `SettingsView`, read once at launch.
enum SavedSettings {
    private static let key = "settings"

    static func load() -> ClientSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(ClientSettings.self, from: data) else { return ClientSettings() }
        return saved
    }

    static func save(_ settings: ClientSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Picks the screen the model has decided on.
struct RootView: View {
    let model: ClientModel

    var body: some View {
        #if DEBUG
        if Automation.showsLookSheet { LookSheet() } else { screens }
        #else
        screens
        #endif
    }

    /// First run when no paired Mac exists, else the library shell; pairing is a sheet over either.
    @ViewBuilder private var screens: some View {
        Group {
            if model.screen == .playing {
                PlayView(model: model)
            } else if model.peers.isEmpty {
                FirstRunView(model: model)
            } else {
                #if os(tvOS)
                TVRootView(model: model)
                #else
                LibraryShell(model: model)
                #endif
            }
        }
        .sheet(isPresented: Binding(get: { pairingHost != nil }, set: { if !$0 { model.cancelPairing() } })) {
            if let host = pairingHost { PairSheet(model: model, host: host) }
        }
    }

    private var pairingHost: FoundHost? {
        if case let .pairing(host) = model.screen { host } else { nil }
    }
}

#if os(iOS)
/// Runs one task inside `beginBackgroundTask`, ended when it finishes or the time is up.
@MainActor final class BackgroundWork {
    private var id = UIBackgroundTaskIdentifier.invalid

    func run(_ work: @escaping @MainActor () async -> Void) {
        finish()
        id = UIApplication.shared.beginBackgroundTask { [weak self] in self?.finish() }
        Task { await work(); finish() }
    }

    private func finish() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
