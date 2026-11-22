#if DEBUG
import AppKit
import Foundation
import PortalHostCore
import PortalHostModel
import PortalKit
import SwiftUI

/// Debug-only scripted runs; nothing here is in a Release build -> .claude/host.md § app
/// Arguments (any `-auto…` makes the app print its log lines, with the pairing code, to stdout, flushed per line):
/// -autoStore <dir>: the pairing store, the log and the game logs go under <dir> (not the account's folders), settings are not
/// saved, the real environment file is ignored, notifications are not asked for; several instances may run
/// -autoLibrary <dir>: the only folder added to the application folders
/// -autoName <name>: the Host's name
/// -autoPair: begin pairing once running
/// -autoFakeGame <path to portal-fakegame>: one extra game, FAKE000000000000, run by that tool
/// -autoSnapshot <png>: with -autoWindow, write the menu's content to the PNG two seconds after the window appeared
/// -autoSnapshotDelay <seconds>: wait this long (0...60, default 2) before the snapshot
/// -autoWindowClose <seconds>: with -autoWindow, close the window after this long; the log then shows "menu opened", "menu read <n>" and
/// "menu closed" (what the model does while the menu is open)
/// -autoWindow: also show the menu's content in an ordinary window titled "nxPortal Host"
enum Automation {
    static func environment() -> HostEnvironment? {
        let args = CommandLine.arguments
        guard args.contains(where: { $0.hasPrefix("-auto") }) else { return nil }
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let base = value("-autoStore").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("nxportal-auto-\(ProcessInfo.processInfo.processIdentifier)")
        let suite = "nxportal-host-auto-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        var settings = HostSettings(name: value("-autoName"))
        if let library = value("-autoLibrary") { settings.folders = [URL(fileURLWithPath: library, isDirectory: true)] }
        HostSettingsStore(defaults: defaults).save(settings)

        var launcher: (any GameLaunching)?
        var extra: [GameApp] = []
        if let tool = value("-autoFakeGame") {
            let app = fakeGameApp(tool: tool, in: base)
            launcher = AppLauncher(apps: { _ in app }, logDirectory: base.appendingPathComponent("logs"))
            extra = [GameApp(titleID: "FAKE000000000000", name: "Fake Game", url: URL(fileURLWithPath: "/dev/null"), streamable: true)]
        }
        var environment = HostEnvironment(
            secrets: FileSecrets(directory: base.appendingPathComponent("secrets")), defaults: defaults, environmentFile: nil,
            logFile: base.appendingPathComponent("host.log"), gameLogDirectory: base.appendingPathComponent("logs"),
            announcer: SilentAnnouncer(), launcher: launcher, extraGames: extra)
        environment.savedChoice = { _, _ in nil }  // an automated run never reads a person's preferences
        environment.singleInstance = !args.contains("-autoStore")
        environment.echo = { line in print(line); fflush(stdout) }
        environment.showWindow = args.contains("-autoWindow")
        environment.pairOnStart = args.contains("-autoPair")
        environment.snapshotFile = value("-autoSnapshot").map { URL(fileURLWithPath: $0) }
        if let delay = value("-autoSnapshotDelay").flatMap(Double.init), delay >= 0, delay <= 60 { environment.snapshotDelay = delay }
        environment.closeWindowAfter = value("-autoWindowClose").flatMap(Double.init).flatMap { $0 >= 0 && $0 <= 600 ? $0 : nil }
        environment.cleanup = { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return environment
    }

    /// The menu's content drawn by SwiftUI itself (the app's own pixels: no screen-recording permission).
    @MainActor static func snapshot(of controller: HostController, to file: URL) {
        let renderer = ImageRenderer(content: MenuView(controller: controller, watchesWindow: false).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    /// `<dir>/FakeGame.app` whose `nxnative` runs the fake game on the socket the Host gives it (`DM_STREAM`).
    private static func fakeGameApp(tool: String, in dir: URL) -> URL {
        let app = dir.appendingPathComponent("FakeGame.app")
        let exe = app.appendingPathComponent("Contents/MacOS/nxnative")
        let quoted = "'" + tool.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try? FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexec \(quoted) --socket \"$DM_STREAM\"\n".write(to: exe, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return app
    }
}

/// An automated run asks for no permission: nothing waits for a person.
struct SilentAnnouncer: PairingAnnouncing {
    func announce(code: String) async {}
    func withdraw() async {}
}
#endif
