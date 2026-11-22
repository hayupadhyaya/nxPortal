import AppKit
import Observation
import PortalHostCore
import PortalHostModel
import PortalKit
import SwiftUI

/// What the menu and the folders window call: the model, plus the app's own questions (remove? rename and end the game?), its
/// log, its quit. The views read and call; the rules are here and in `HostModel` -> .claude/host.md § app
@MainActor @Observable
final class HostController {
    static let shutdownLimit: TimeInterval = 12

    /// Every quit and every signal joins the one stop.
    @ObservationIgnored private var gate: ShutdownGate!
    let model: HostModel
    /// A device the person asked to remove and has not yet confirmed.
    private(set) var removalAsked: PairedDevice?
    /// A new name the person asked for while a game was active, waiting for a yes.
    private(set) var renameAsked: String?
    var nameDraft: String

    @ObservationIgnored private let environment: HostEnvironment
    @ObservationIgnored private let log: HostLogFile
    @ObservationIgnored private let gameEnvironmentProblem: Bool
    @ObservationIgnored private var windows: [String: NSWindow] = [:]
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []

    init(environment: HostEnvironment) {
        self.environment = environment
        gate = ShutdownGate(limit: HostController.shutdownLimit, finally: { environment.cleanup?() })  // once, on every path
        log = HostLogFile(url: environment.logFile)
        var variables: [String: String] = [:]
        var problem = false
        if let file = environment.environmentFile {
            switch EnvironmentFile.read(file) {
            case .absent: break
            case let .variables(values): variables = values
            case .ignored: problem = true
            }
        }
        gameEnvironmentProblem = problem
        let captured = variables
        model = HostModel(store: HostSettingsStore(defaults: environment.defaults), secrets: environment.secrets,
                          announcer: environment.announcer, launcher: environment.launcher, extraGames: environment.extraGames,
                          logDirectory: environment.gameLogDirectory, gameEnvironment: { _ in captured },
                          optionsFile: environment.optionsFile, savedChoice: environment.savedChoice)
        nameDraft = model.settings.name ?? ""
        (environment.secrets as? FileSecrets)?.tightenFolder()  // a folder that exists with wider modes
        model.onEvent = { [unowned self] event in record(event) }
    }

    // MARK: running

    /// Starts the Host and, in an automated run, the pairing.
    func begin() {
        if gameEnvironmentProblem { log.write(Strings.environmentFileLog) }
        installSignalHandlers()
        Task {
            await model.start()
            if gameEnvironmentProblem { model.show(message: Strings.environmentFileIgnored) }  // `start()` clears the message
            if environment.pairOnStart { await model.beginPairing() }
            #if DEBUG
            if let echo = environment.echo { model.onMenuEvent = { echo($0) } }  // an automated run shows when the menu reads
            #endif
            if environment.showWindow { showMenuWindow() }
            #if DEBUG
            if let after = environment.closeWindowAfter {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(after * 1e9))
                    windows["menu"]?.close()
                }
            }
            if let file = environment.snapshotFile {
                try? await Task.sleep(nanoseconds: UInt64(environment.snapshotDelay * 1e9))  // the first refresh and the pairing code have landed
                await model.refresh()  // the numbers as of now, as an open menu would read them
                Automation.snapshot(of: self, to: file)
            }
            #endif
        }
    }

    private func record(_ event: HostEvent) {
        log.write(HostEventLine.text(event, showCode: false))
        guard let echo = environment.echo else { return }
        echo(HostEventLine.text(event, showCode: true))
        if case let .status(.pairing(code, _)) = event { echo("pairing code: \(code)") }
    }

    /// SIGTERM and SIGINT stop the Host, wait for it (`shutdown()`) and exit 0. Not `NSApp.terminate`: that waits in a nested
    /// event loop inside this main-queue callback, where the stop's own main-actor work can never run.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [unowned self] in
                Task {
                    await shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Stops the Host and waits for it, at most `shutdownLimit` seconds; a second request joins the first.
    func shutdown() async {
        await gate.run { [self] in await model.stop() }
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: the menu

    /// The model's message, unless the status line already says it.
    var shownMessage: String? {
        if case .failed = model.phase { return nil }
        return model.message
    }

    var statusLine: String { Strings.statusLine(phase: model.phase, status: model.status, games: model.games, preparingHeadline: model.preparingHeadline) }

    var isRunning: Bool { if case .running = model.phase { true } else { false } }

    var gameCanQuit: Bool { model.games.contains { $0.state != .idle } }

    /// The menu's window is on screen / went away: the model reads the service while it is open and only then
    /// (`HostModel.menuOpened`), because the games' run states and the session's numbers change without a status change.
    func menuOpened() { model.menuOpened() }
    func menuClosed() { model.menuClosed() }
    func menuStillOpen() { model.menuStillOpen() }

    func pair() { Task { await model.beginPairing() } }
    func cancelPairing() { Task { await model.cancelPairing() } }
    func quitGame() { Task { await model.quitGame() } }
    func refresh() { Task { await model.refresh() } }

    /// The device whose name is being edited in the list, and the draft; one at a time.
    private(set) var deviceRenaming: Data?
    var deviceNameDraft = ""

    func beginRenameDevice(_ device: PairedDevice) {
        removalAsked = nil
        deviceRenaming = device.id
        deviceNameDraft = model.renameDraft(for: device)
    }
    func cancelRenameDevice() { deviceRenaming = nil }
    /// An empty draft removes the Host's own name (the device's own shows again); the model cleans and bounds the rest.
    func saveDeviceName() {
        guard let id = deviceRenaming, let device = model.devices.first(where: { $0.id == id }) else { return cancelRenameDevice() }
        let draft = deviceNameDraft
        deviceRenaming = nil
        Task { await model.rename(device, to: draft) }
    }

    func askRemove(_ device: PairedDevice) { deviceRenaming = nil; removalAsked = device }
    func keepDevice() { removalAsked = nil }
    func confirmRemove() {
        guard let device = removalAsked else { return }
        removalAsked = nil
        Task { await model.remove(device) }
    }

    /// Renaming restarts the Host and ends a running or paused game: when one is active (read after a `refresh()`, the status
    /// does not change while a code is open) the person is asked first.
    func askRename() {
        let name = nameDraft
        Task {
            await model.refresh()
            if model.gameIsActive { renameAsked = name } else { await model.rename(name) }
        }
    }
    func keepName() { renameAsked = nil; nameDraft = model.settings.name ?? "" }
    func confirmRename() {
        guard let name = renameAsked else { return }
        renameAsked = nil
        Task { await model.rename(name) }
    }

    var nameCanChange: Bool {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (model.settings.name ?? "")
    }

    // MARK: folders

    func removeFolder(_ url: URL) { Task { await model.removeFolder(url) } }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = Strings.chooseFolder
        panel.message = Strings.chooseFolderMessage
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addFolder(url) }
    }

    // MARK: windows

    func showFolders() {
        show(id: "folders", title: Strings.foldersTitle) { FoldersView(controller: self) }
    }

    func showMenuWindow() {
        show(id: "menu", title: Strings.windowTitle) { MenuView(controller: self) }
    }

    private func show<Content: View>(id: String, title: String, @ViewBuilder content: () -> Content) {
        let window = windows[id] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
            w.title = title
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            windows[id] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
