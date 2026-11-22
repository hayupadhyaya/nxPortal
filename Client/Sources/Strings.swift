import Foundation
import PortalKit
import PortalPlayer

/// Every sentence the views add; English for now. Sentences the model owns are in `Messages` (PortalPlayer).
enum Strings {
    // Macs
    static let macsTitle = "Macs"
    static let yourMacs = "Your Macs"
    static let nearby = "Nearby"
    static let pairAMac = "Pair a Mac…"
    static let macsFooter = "A Mac shows up here when nxPortal Host is open on it."
    static let settings = "Settings"
    static let forgetPairedMacs = "Forget paired Macs"
    static let forgetConfirmTitle = "Forget every paired Mac?"
    static let forgetConfirmMessage = "You will have to pair with each Mac again."
    static let cancel = "Cancel"
    static let done = "Done"
    static func playing(_ game: String) -> String { Messages.playing(game) }
    static func switchTitle(_ mac: String) -> String { Messages.switchTitle(mac) }
    static func switchMessage(game: String, mac: String) -> String { Messages.switchMessage(game: game, mac: mac) }
    static let switchAction = "Switch"
    static func macsButton(_ mac: String?) -> String { Messages.macsButton(mac) }

    // First run
    static let firstRunTitle = "Play the games on your Mac"
    static let firstRunText = "nxPortal shows your Mac's games here and streams them over your home network."
    static let firstRunSteps = ["Open nxPortal Host on your Mac", "Choose the Mac when it shows up below", "Type the code from the Mac's menu"]
    static let lookingForMacs = "Looking for Macs on this network…"
    static let stillLooking = "Still looking. Is nxPortal Host open on your Mac?"
    static let chooseYourMac = "Choose your Mac"
    static let chooseYourMacText = "These Macs on your network have nxPortal Host open."
    static let readyToPair = "Ready to pair"
    static let firstRunFooter = "Don't see your Mac? Check that it is on the same Wi-Fi network and that nxPortal Host is open on it."
    static let openSettings = "Open Settings"
    static let howToSetUp = "How to set up a Mac"

    // Setup help
    static let helpNeeds = "What you need"
    static let helpNeedsItems = ["An Apple silicon Mac with macOS 14 or later.", "nxPortal Host open on that Mac.",
                                 "A game on that Mac that supports streaming.", "The Mac and this device on the same network."]
    static let helpSteps = "Steps"
    static let helpStepItems = ["Open nxPortal Host on the Mac.", "In its menu, choose \"Pair a Device\". The menu shows a six-digit code.",
                                "Choose the Mac in this app and type the code."]
    static let helpStill = "Still nothing?"
    static let helpStillItems = ["Allow Local Network for nxPortal in Settings.", "Check that both are on the same Wi-Fi network.", "Wake the Mac."]

    // Banner
    static let retry = "Retry"

    // Settings: session numbers
    static let recordSessions = "Keep session numbers on this device"
    static let recordSessionsNote = "A small text file per session; it stays on this device."

    // Pairing
    static func pairTitle(mac: String) -> String { Messages.pairTitle(mac: mac) }
    static func pairText(mac: String) -> String { Messages.pairText(mac: mac) }
    static let pairNote = "The code works for two minutes. You only pair once."
    static func codeLabel(_ digits: Int) -> String { Messages.codeLabel(digits) }
    static let deleteDigit = "Delete digit"
    static let close = "Close"

    // Library
    static let refresh = "Refresh"
    static let gamesTitle = "Games"
    static let continueTitle = "Continue"
    static let allGames = "All games"
    static let options = "Options"
    static let more = "More"
    static let play = "Play"
    static let back = "Games"
    static func onMac(_ mac: String) -> String { Messages.onMac(mac) }
    // Library sentences (`LibraryText`, tested in PortalPlayer)
    static func tileValue(_ state: LibraryText.TileState) -> String { LibraryText.tileValue(state) }
    static let tileHint = LibraryText.tileHint
    static let focusedLabel = LibraryText.focusedLabel
    static let focusHint = LibraryText.focusHint
    static func focusState(_ state: LibraryText.TileState, lastPlayed: Bool) -> String? { LibraryText.focusState(state, lastPlayed: lastPlayed) }
    static let rebuildNeeded = LibraryText.rebuildNeeded
    static func continueState(_ game: GameEntry, preparing: Preparing? = nil, playsHere: Bool = true) -> String {
        LibraryText.continueState(game, preparing: preparing, playsHere: playsHere)
    }
    static func continueLabel(_ game: GameEntry, preparing: Preparing? = nil, playsHere: Bool = true) -> String {
        LibraryText.continueLabel(game, preparing: preparing, playsHere: playsHere)
    }
    static func continueAction(_ game: GameEntry) -> String { LibraryText.continueAction(game) }
    static func emptyLibrary(mac: String) -> String { LibraryText.empty(mac: mac) }
    static let libraryLoading = LibraryText.loading
    static func libraryCouldNotLoad(mac: String) -> String { LibraryText.couldNotLoad(mac: mac) }
    static func gameCount(_ n: Int) -> String { LibraryText.gameCount(n) }

    // Play
    static let menuChord = "Menu + Options opens the in-play menu"
    static let menuChordNote = "Hold the controller's Menu and Options buttons together for half a second."
    static let disconnect = "Disconnect"
    static let disconnectCaption = "The game pauses on the Mac"
    static let quitGame = "Quit game"
    static let noController = "No controller connected"
    static func controller(_ name: String) -> String { Messages.controller(name) }
    static let backToGames = "Back to games"
    /// Over the frozen picture while the Mac has been silent for a second (the game keeps running for 10 s).
    static let reconnecting = "Reconnecting…"
    static func reconnectingTitle(mac: String) -> String { Messages.reconnectingTitle(mac: mac) }
    static func reconnectingBody(game: String) -> String { Messages.reconnectingBody(game: game) }
    static let stopAndGoToGames = "Stop and go to games"
    static let sessionEndedTitle = "The session ended"
    static let reconnect = "Reconnect"
    static let smoothPicture = "Smooth picture"
    static let smoothPictureNote = "Even frame pacing"
    static let numbers = "Numbers"
    /// The numbers panel, one string per line (`PanelText`, tested in PortalPlayer).
    static func panelLines(level: PanelLevel, stats: ClientModel.PlayStats?, pacing: PicturePacing, note: PanelText.GameNote?) -> [String] {
        PanelText.lines(level: level, stats: stats, pacing: pacing, note: note)
    }
    static func levelName(_ level: PanelLevel) -> String { PanelText.name(level) }
    static func menuSubtitle(mac: String?, width: Int, height: Int, fps: Int) -> String {
        PanelText.menuSubtitle(mac: mac, width: width, height: height, fps: fps)
    }

    // Preparing (`PreparingText`, tested in PortalPlayer)
    static func tileCaption(percent: Int?) -> String { PreparingText.tileCaption(percent: percent) }

    // In-play menu (`§ screen-play`)
    static let menuTitle = "Menu"
    static let nowTitle = "Now"
    static let nowCaption = "Changes at once"
    static let newConnectionTitle = "Needs a new connection"
    static let newConnectionCaption = "The game keeps going"
    static let streamSize = "Stream size"
    static let frameRate = "Frame rate"
    static let applyAndReconnect = "Apply and reconnect"
    static let pendingChange = "Changes waiting"
    static func disconnectNote(preparing: Bool) -> String { PreparingText.disconnectNote(preparing: preparing) }
    static let closeHint = "Close with ✕ · a tap outside · B or Home on a controller"
    static let closeHintTV = "Back closes the menu"
    static let closeMenu = "Close menu"

    // Per-game options (`OptionText`, tested in PortalPlayer)
    static let optionsTitle = OptionText.title
    static let optionsCaption = OptionText.caption
    static func optionChip(_ chip: OptionText.Chip) -> String { chip.text }
    static let optionCannotChange = OptionText.cannotChange
    static let noGameOptions = OptionText.noOptions
    static let optionsLoading = OptionText.loading
    static let optionsCouldNotLoad = OptionText.couldNotLoad
    static let optionsReset = OptionText.reset
    static let optionsFooter = OptionText.footer
    static let optionsShowFewer = OptionText.showFewer
    static func optionsMore(count: Int) -> String { OptionText.moreRow(count: count) }
    static let allGameOptions = OptionText.allOptions
    static let nextStartTitle = OptionText.nextStartTitle
    static let nextStartCaption = OptionText.nextStartCaption
    static func nextStartNote(game: String) -> String { OptionText.nextStartNote(game: game) }
    static func sizeHint(_ options: GameOptions?) -> String? { OptionRows.sizeHint(options) }

    // Settings
    static let settingsTitle = "Settings"
    static let picture = "Picture"
    static let maxSize = "Largest stream size"
    static let maxSizeNote = "Never above what a game renders"
    static func sizeNote(_ note: String?) -> String? { note }
    static func streamSizeLine(_ line: String) -> String { line }
    static let maxFps = "Frame rate limit"
    static let bitrate = "Bitrate ceiling"
    static let bitrateNote = "The stream adapts below this"
    static let pictureFooter = "Size and frame rate apply the next time you connect."
    static let numbersTitle = "Numbers"
    static let playSound = "Play sound"
    static func mbitOption(_ n: Int) -> String { Messages.mbitOption(n) }
    static let deviceGroup = DeviceNameText.group
    static let deviceNameTitle = DeviceNameText.title
    static let deviceNameFooter = DeviceNameText.footer
    static func deviceNamePlaceholder() -> String { DeviceNameText.placeholder() }
    static let sound = "Sound"
    static let soundBuffer = "Sound buffer"
    static let soundBufferAutomatic = "Automatic"
    static let controls = "Controls"
    static let controllerGroup = "Controller"
    static let touchGroup = TouchText.groupTitle
    static let touchLayoutTitle = TouchText.layoutTitle
    static let touchLayoutNote = TouchText.layoutNote
    static let layoutForNewGames = TouchText.layoutForNewGames
    static let touchHaptics = TouchText.hapticsTitle
    static let touchHapticsNote = TouchText.hapticsNote
    static let acknowledgements = TouchText.acknowledgements
    static let controllerConnected = TouchText.controllerConnected
    static let connectController = TouchText.connectController
    static var touchLayoutChoices: [(TouchLayout, String)] { TouchText.choices }
    static func showsTouchLayoutRow(gameControllers: Int) -> Bool { TouchText.showsLayoutRow(gameControllers: gameControllers) }
    static let aboutTitle = "About"
    static let macsGroup = "Macs"
    static let versionLabel = "Version"
    static func version(_ short: String, build: String) -> String { "\(short) (\(build))" }
    static let padLayout = "Button layout"
    static let deviceMotion = "Motion"
    static let appliesNext = "Changes apply the next time you connect."
    static let layoutAuto = "Automatic"
    static let layoutByLabel = "By label"
    static let layoutByPosition = "By position"
    static let motionAuto = "Automatic"
    static let motionAlways = "This device"
    static let motionNever = "Controller only"
    static func fpsOption(_ n: Int) -> String { Messages.fpsOption(n) }
    static func msOption(_ n: Int) -> String { Messages.msOption(n) }
}
