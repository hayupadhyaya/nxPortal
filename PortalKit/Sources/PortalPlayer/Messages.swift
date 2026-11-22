import PortalKit

/// Every sentence the model can show; English for now -> .claude/client.md § model
public enum Messages {
    /// `mac` is the Mac's name ("the Mac" when none is known).
    public static func refusal(_ r: Refusal, mac: String = theMac) -> String {
        switch r {
        case let .busy(device): "\(mac) is playing on \(shown(device))."
        case let .version(host): "\(mac) has a different version of nxPortal Host (protocol \(host), this app \(ProtocolVersion.network)). Update the older one."
        case .unpaired: "\(mac) no longer knows this device. Pair again."
        }
    }

    public static func pairing(_ r: PairResult, mac: String = theMac) -> String {
        switch r {
        case .ok: "Paired."
        case let .wrongCode(left): wrongCode(triesLeft: left)
        case .locked: "Too many wrong codes. Show a new code on \(mac) and try again."
        case .expired: "The code ran out. Show a new code on \(mac)."
        }
    }

    public static let theMac = "the Mac"

    /// A device name from the wire, cleaned and bounded again (never trusted); "another device" when none is left.
    static func shown(_ device: String?) -> String { device.flatMap(DeviceName.clean) ?? "another device" }

    /// "2 tries left" is added from two tries down; the singular is "1 try left".
    public static func wrongCode(triesLeft: Int) -> String {
        let base = "That code didn't match."
        guard triesLeft <= 2 else { return base }
        return base + (triesLeft == 1 ? " 1 try left." : " \(triesLeft) tries left.")
    }

    public static func cannotReach(_ mac: String) -> String { "Cannot reach \(mac)." }

    public static func ended(reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "The game ended." }
        return "The game ended: \(reason)."
    }

    /// The game's name when none is known.
    public static let theGame = "The game"

    /// The ended card's sentence: the session is gone, the game waits paused on the Mac.
    public static func sessionEnded(mac: String, game: String) -> String { "\(sentence(.stoppedAnswering, mac: mac)) \(game) is paused there and waits." }
    public static func reconnectingTitle(mac: String) -> String { "Reconnecting to \(mac)" }
    public static func reconnectingBody(game: String) -> String { "\(game) is paused until you're back. Try moving closer to the Wi-Fi router." }

    public static let busyReconnecting = "Still reconnecting to the Mac."

    /// The Host's reason for refusing a launch ("<game> is running"), as a sentence.
    public static func launchReply(_ reason: String) -> String {
        guard let last = reason.last, !".!?".contains(last) else { return reason }
        return reason + "."
    }

    public static let connectionLost = "Connection to the Mac lost. Trying again…"
    public static let unreachable = "The Mac did not answer."
    public static let mediaPathBlocked = "The Mac answers, but its video cannot reach this device. Check that both are on the same network."
    public static let codeDidNotMatch = "The code did not match. Start pairing on the Mac again."
    public static let quitUnconfirmed = "The Mac did not confirm the game quit."
    public static let discoveryBlocked = "nxPortal can't look for Macs. Allow Local Network for nxPortal in Settings."
    public static let storeFailed = "This device's pairing data could not be read. Forget paired Macs in Settings, then pair again."

    // MARK: the library's banner

    /// Why the current Mac's library cannot be used; each case has its own sentence.
    public enum Problem: Equatable, Sendable {
        case cannotReach, refused(Refusal), connectionLost, stoppedAnswering, mediaPathBlocked, didNotAnswer, storeFailed, codeDidNotMatch
        /// The library session gave the Mac to another device (its shown name; nil: not named).
        case inUse(device: String?)
        /// A sentence already made (a pairing result).
        case other(String)
    }

    /// The problem as one sentence; `mac` is the current Mac's name.
    public static func sentence(_ p: Problem, mac: String) -> String {
        switch p {
        case .cannotReach: cannotReach(mac)
        case let .refused(r): refusal(r, mac: mac)
        case .connectionLost: connectionLost
        case .stoppedAnswering: "\(mac) stopped answering."
        case .mediaPathBlocked: mediaPathBlocked
        case .didNotAnswer: unreachable
        case .storeFailed: storeFailed
        case .codeDidNotMatch: codeDidNotMatch
        case let .inUse(device): "\(mac) is now in use on \(shown(device))."
        case let .other(text): text
        }
    }

    /// The library's banner. Only "Cannot reach" adds that the games are the last known and what to check
    /// (or, with discovery refused, the Local Network hint); every other case is its own sentence.
    public static func banner(_ p: Problem, mac: String, discoveryBlocked: Bool = false) -> String {
        let text = sentence(p, mac: mac)
        guard p == .cannotReach else { return text }
        return text + (discoveryBlocked ? " " + Messages.discoveryBlocked : " Showing the last known games. Check that the Mac is awake and on this network.")
    }

    // MARK: sentences the app's views show

    public static func playing(_ game: String) -> String { "Playing \(game)" }
    public static func switchTitle(_ mac: String) -> String { "Switch to \(mac)?" }
    public static func switchMessage(game: String, mac: String) -> String { "\(game) is playing on \(mac). It pauses there and waits for you." }
    public static func pairTitle(mac: String) -> String { "Pair with \(mac)" }
    public static func pairText(mac: String) -> String { "Type the six-digit code shown in the nxPortal menu on \(mac)." }
    /// Under a refused code: asked for a wrong code only (a locked or expired code needs a new code on the Mac, not a retyping).
    public static func pairRetry(_ result: PairResult?, mac: String) -> String? {
        guard case .wrongCode? = result else { return nil }
        return "Check the code on \(mac) and type it again."
    }
    public static func codeLabel(_ digits: Int) -> String { "Code, \(digits) of 6 digits" }
    public static func onMac(_ mac: String) -> String { "On \(mac)" }
    public static func controller(_ name: String) -> String { "Controller: \(name)" }
    public static func macsButton(_ mac: String?) -> String { mac ?? "Macs" }
    public static func mbitOption(_ n: Int) -> String { "\(n) Mbit/s" }
    public static func fpsOption(_ n: Int) -> String { "\(n) fps" }
    public static func msOption(_ n: Int) -> String { "\(n) ms" }
}
