import Foundation

/// A type that holds key material (or the pairing code) prints only its name, however it is printed, so a log line, a crash
/// report or `dump` never carries a secret -> .claude/portalkit.md § secrets
protocol Redacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}

extension Redacted {
    public var description: String { "\(Self.self)(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension Identity: Redacted {}
extension SessionKeys: Redacted {}
extension PairingHost: Redacted {}
extension PairingClient: Redacted {}
extension StreamSealer: Redacted {}
extension StreamOpener: Redacted {}
extension DatagramSealer: Redacted {}
extension DatagramOpener: Redacted {}
