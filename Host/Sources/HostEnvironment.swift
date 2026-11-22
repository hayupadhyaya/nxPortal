import Foundation
import PortalHostCore
import PortalHostModel
import PortalKit

/// Everything the app takes from outside itself: where its files are and what stands in for the real game launcher. The
/// standard one is the person's own account; `-auto…` runs (Debug only, `Automation.swift`) replace it.
struct HostEnvironment {
    var secrets: any SecretStoring
    var defaults: UserDefaults
    /// nil: no game environment file is read.
    var environmentFile: URL?
    /// Where the per-game choices of paired devices are kept; nil: in memory only (every automated run).
    var optionsFile: URL?
    /// Reads an app's own saved choice; nil = the person's real preferences (the standard environment). Every automated run
    /// gives one that returns nothing: no `-auto` run reads a person's preferences.
    var savedChoice: (@Sendable (String, String) -> String?)?
    var logFile: URL
    var gameLogDirectory: URL
    var announcer: any PairingAnnouncing
    var launcher: (any GameLaunching)?
    var extraGames: [GameApp] = []
    /// Only the standard environment keeps to one instance.
    var singleInstance = true
    /// Also print the log lines (with the pairing code) to stdout, flushed per line.
    var echo: (@MainActor (String) -> Void)?
    var showWindow = false
    var pairOnStart = false
    /// Debug runs: write the shown window to this PNG after a moment (the app's own pixels: no screen-recording permission).
    var snapshotFile: URL?
    /// Seconds to wait before the snapshot (a device that connects meanwhile is in it).
    var snapshotDelay: Double = 2
    /// Debug runs: close the menu window this many seconds after it was shown.
    var closeWindowAfter: Double?
    /// Run when the app stops.
    var cleanup: (@MainActor () -> Void)?

    /// `~/Library/Application Support/nxPortal` (0700, files 0600) and `~/Library/Logs/nxPortal`: the pairing store is in files, not
    /// the Keychain, in every build (a rebuilt or ad hoc signed app is asked for Keychain permission again; this app runs on a Mac
    /// nobody sits at) -> .claude/host.md § app
    static func standard() -> HostEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/nxPortal", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/nxPortal", isDirectory: true)
        return HostEnvironment(
            secrets: FileSecrets(directory: support), defaults: .standard,
            environmentFile: support.appendingPathComponent("environment.json"),
            optionsFile: support.appendingPathComponent("options.json"),
            logFile: logs.appendingPathComponent("host.log"), gameLogDirectory: logs,
            announcer: PairingNotifier(centre: SystemNotificationCentre(), title: Strings.pairingNotificationTitle))
    }

    static func current() -> HostEnvironment {
        #if DEBUG
        if let automated = Automation.environment() { return automated }
        #endif
        return .standard()
    }
}
