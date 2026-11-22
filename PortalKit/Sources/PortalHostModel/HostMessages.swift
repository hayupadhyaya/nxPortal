#if os(macOS)
import Foundation
import PortalHostCore
import PortalKit

/// Every sentence the model shows. Plain text: no identifier, address, path or key -> .claude/host.md § model
public enum HostMessages {
    /// The service is not serving; `reason` is its own text for people. It is tried again.
    public static func serviceFailed(_ reason: String) -> String {
        var text = reason
        while text.hasSuffix(".") { text.removeLast() }
        return "The Host is not running: \(text). It will try again."
    }

    /// The saved identity cannot be read: not tried again by itself (that cannot help).
    public static let identityUnreadable = "The Host's saved identity cannot be read, so the Host did not start. Starting it again tries once more."

    /// The Host could not prepare its connection to games: not tried again by itself.
    public static let setupFailed = "The Host could not prepare its connection to games, so it did not start."

    /// The reason shown when the service gave none.
    public static let unknownReason = "something went wrong"

    public static let notRunning = "The Host is not running."

    public static let folderMissing = "That folder could not be found."

    public static func couldNotRemove(_ deviceName: String) -> String {
        "\(deviceName) could not be removed: the change could not be saved. It is disconnected but still paired."
    }

    public static func couldNotRename(_ deviceName: String) -> String {
        "\(deviceName) could not be renamed: the change could not be saved."
    }

    /// The second status line while a session is live: "Test Mac · 60 fps · 48 Mbit/s" (the frame rate as measured; left out until it is).
    public static func statusDetail(device: String, fps: Int?, bps: UInt32) -> String {
        let tenths = Int((Double(bps) / 100_000).rounded())
        let rate = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
        let frames = fps.map { " \u{00B7} \($0) fps" } ?? ""  // not measured yet: no frame rate, never a guess
        return "\(device)\(frames) \u{00B7} \(rate) Mbit/s"
    }

    /// The headline while the game being played still prepares its graphics.
    public static func preparingGame(_ game: String, for device: String) -> String { "Preparing \(game) for \(device)" }

    /// A game row's tag while it prepares its graphics.
    public static func preparingTag(percent: Int) -> String { "preparing \(percent) %" }
    /// The tag for a game's progress: its percentage, or none while the game has not said how far it is.
    public static func preparingTag(of p: Preparing) -> String {
        guard p.total > 0 else { return "preparing" }
        return preparingTag(percent: p.percent)
    }

    /// How much of the pairing code's window is left, 0...1, for the menu's time bar; `until` is the status's own end.
    public static func codeTimeLeft(until: Date, now: Date, lifetime: TimeInterval = PairingLimits.lifetime) -> Double {
        guard lifetime > 0 else { return 0 }
        return min(max(until.timeIntervalSince(now) / lifetime, 0), 1)
    }

    /// What a failed call shows: the Host's own text for its errors, a plain line for anything else.
    public static func problem(_ error: any Error) -> String {
        if let known = error as? HostServiceError, let text = known.errorDescription { return text }
        return "Something went wrong."
    }
}
#endif
