import Foundation
import PortalHostCore
import PortalHostModel
import PortalKit

/// Every sentence the views add; English for now. Sentences the model owns are in `HostMessages` (PortalHostModel).
enum Strings {
    // Status
    static let starting = "Starting…"
    static let stopped = "Stopped"
    static let ready = "Ready"
    static func playing(game: String, device: String) -> String { "Playing \(game) on \(device)" }
    static func connected(device: String) -> String { "\(device) is connected" }
    static func paused(game: String) -> String { "Paused: \(game)" }
    static func startingGame(_ name: String) -> String { "Starting \(name)…" }
    static func notRunning(_ reason: String) -> String { "Not running: \(reason). Retrying…" }

    /// The line at the top of the menu. A game still starting (it may prepare its graphics for minutes) shows as such until
    /// the model reports a picture or a pause.
    static func statusLine(phase: HostModel.Phase, status: HostStatus, games: [GameEntry], preparingHeadline: String? = nil) -> String {
        switch phase {
        case .stopped: return stopped
        case .starting: return starting
        case let .failed(text):
            // A failure the model does not retry carries its own sentence.
            return text == HostMessages.identityUnreadable || text == HostMessages.setupFailed ? text : notRunning(text)
        case .running:
            switch status {
            case .idle, .pairing:
                if let starting = games.first(where: { $0.state == .starting }) { return startingGame(starting.name) }
                return ready
            case let .live(device, _, game):
                if let starting = games.first(where: { $0.state == .starting }) { return startingGame(starting.name) }
                if let preparingHeadline { return preparingHeadline }  // the game on this line still prepares its graphics
                return game.map { playing(game: $0, device: device) } ?? connected(device: device)
            case let .paused(game): return paused(game: game)
            case let .failed(text): return notRunning(text)
            }
        }
    }

    // Pairing
    static let pairDevice = "Pair a Device"
    static let pairingCodeLabel = "Pairing code"
    static let cancel = "Cancel"
    /// `seconds` left of the code's window, as "1:59".
    static func timeLeft(seconds: Int) -> String {
        let s = max(seconds, 0)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
    /// A code as "123 456".
    static func grouped(code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    // Devices
    static let devices = "Devices"
    static let noDevices = "No devices paired yet."
    static let connectedTag = "connected"
    static let remove = "Remove"
    static let renameDevice = "Rename"
    static let saveName = "Save"
    static let deviceNamePlaceholder = "Name"
    static func removeQuestion(_ name: String) -> String { "Remove \(name)? It will have to pair again." }
    static let keep = "Keep"

    // Games
    static let games = "Games"
    static let noGames = "No games found."
    static let rebuildNeeded = "rebuild needed"
    static let playingTag = "playing"
    static let pausedTag = "paused"
    static let startingTag = "starting…"
    /// The tag of a game that prepares its graphics, from the model's own sentence.
    static func preparingTag(_ progress: Preparing) -> String { HostMessages.preparingTag(of: progress) }
    static func preparingTag(percent: Int) -> String { HostMessages.preparingTag(percent: percent) }
    static let quitGame = "Quit Game"
    static let refresh = "Refresh"

    // Name
    static let name = "Name"
    static let rename = "Rename"
    static let renameEndsGame = "Renaming restarts the Host and ends the game that is running."
    static let renameAnyway = "Rename and End Game"

    // Folders
    static let gameFolders = "Game Folders…"
    static let foldersTitle = "Game Folders"
    static let foldersFixed = "Always searched"
    static let foldersAdded = "Added by you"
    static let noAddedFolders = "No folders added."
    static let add = "Add…"
    static let chooseFolder = "Choose"
    static let chooseFolderMessage = "Choose a folder that holds game apps."

    // Window titles and quit
    static let windowTitle = "nxPortal Host"
    static let quit = "Quit nxPortal Host"

    // Notifications
    static let pairingNotificationTitle = "nxPortal pairing code"
}

// App log and files (one place for every sentence the app writes)
extension Strings {
    static let environmentFileIgnored = "The game environment file could not be used and was ignored: it must be one object of text values."
    static let environmentFileLog = "environment.json ignored: not one object of text values, or not readable"
    static func gameTag(_ state: GameRunState) -> String? {
        switch state {
        case .idle: return nil
        case .starting: return startingTag
        case .running: return playingTag
        case .paused: return pausedTag
        }
    }
}
