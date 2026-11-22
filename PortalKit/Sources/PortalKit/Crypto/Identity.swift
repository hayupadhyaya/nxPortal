import CryptoKit
import Foundation

/// A device's long-term X25519 key. Never log or print its bytes.
public struct Identity: Sendable {
    let key: Curve25519.KeyAgreement.PrivateKey

    public init() { key = Curve25519.KeyAgreement.PrivateKey() }

    /// Throws CryptoKit's error for a length other than 32.
    public init(rawPrivateKey: Data) throws {
        key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    public var rawPrivateKey: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.rawRepresentation }

    /// The Host's discovery ID for this key.
    public var discoveryID: String { Self.discoveryID(publicKey: publicKey) }

    /// 16 lower-case hex digits: the first 8 bytes of SHA-256 of a Host's public key. The Host advertises it (`id=`) and a
    /// client computes it from a stored key to match a found service to a paired Host.
    public static func discoveryID(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// A device that completed pairing: its static public key and its own name. The Host's file also keeps the Host's rename
/// (`alias`), the device's kind (from its `hello`) and when it paired (`added`); a file written without them loads with
/// each nil -> .claude/host.md § pairing-store
public struct PairedPeer: Codable, Equatable, Sendable {
    public var key: Data, name: String
    public var alias: String?
    public var kind: DeviceKind?
    public var added: Date?
    public init(key: Data, name: String, alias: String? = nil, kind: DeviceKind? = nil, added: Date? = nil) {
        self.key = key; self.name = name; self.alias = alias; self.kind = kind; self.added = added
    }

    private enum CodingKeys: String, CodingKey { case key, name, alias, kind, added }

    /// `key` and `name` are required; the rest are read leniently (a value of another type is nil, not a failure that
    /// would lose every pairing).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(Data.self, forKey: .key)
        name = try c.decode(String.self, forKey: .name)
        alias = try? c.decodeIfPresent(String.self, forKey: .alias)
        kind = try? c.decodeIfPresent(DeviceKind.self, forKey: .kind)
        added = try? c.decodeIfPresent(Date.self, forKey: .added)
    }

    /// The first 8 hex digits of SHA-256 of the key: how a log line names this device, never its name.
    public var tag: String { Identity.tag(publicKey: key) }
}

extension Identity {
    /// 8 lower-case hex digits: the start of `discoveryID(publicKey:)`.
    public static func tag(publicKey: Data) -> String { String(discoveryID(publicKey: publicKey).prefix(8)) }
}
