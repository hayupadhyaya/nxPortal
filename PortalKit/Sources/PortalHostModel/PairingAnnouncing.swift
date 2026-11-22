#if os(macOS)
import Foundation

/// Tells the person a pairing code is waiting (the app posts a notification) -> .claude/host.md § model
public protocol PairingAnnouncing: Sendable {
    /// Once per new code.
    func announce(code: String) async
    /// The code is no longer on offer (used, expired, cancelled, or the Host stopped).
    func withdraw() async
}
#endif
