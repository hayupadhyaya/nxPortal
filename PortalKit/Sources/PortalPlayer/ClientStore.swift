import Foundation
import PortalKit

public enum ClientStoreError: Error, Equatable {
    /// A stored value that does not decode; never replaced silently.
    case corrupt(key: String)
}

/// This device's identity and the Macs it paired with -> .claude/client.md § store
public struct ClientStore: Sendable {
    static let identityKey = "identity", hostsKey = "hosts", lastHostKey = "lastHost"
    private let secrets: any SecretStoring

    public init(secrets: any SecretStoring) { self.secrets = secrets }

    /// Made and saved on first use.
    public func identity() throws -> Identity {
        if let raw = try secrets.read(Self.identityKey) {
            guard raw.count == 32, let id = try? Identity(rawPrivateKey: raw) else { throw ClientStoreError.corrupt(key: Self.identityKey) }
            return id
        }
        let id = Identity()
        try secrets.write(Self.identityKey, id.rawPrivateKey)
        return id
    }

    public func hosts() throws -> [PairedPeer] {
        guard let data = try secrets.read(Self.hostsKey) else { return [] }
        guard let list = try? JSONDecoder().decode([PairedPeer].self, from: data) else {
            throw ClientStoreError.corrupt(key: Self.hostsKey)
        }
        return list
    }

    /// Replaces the entry with the same key.
    public func save(host: PairedPeer) throws {
        var list = try hosts()
        list.removeAll { $0.key == host.key }
        list.append(host)
        try write(list)
    }

    /// The Mac the app opens on: its 32-byte public key (not secret); any other length is `.corrupt`.
    public func lastHostKey() throws -> Data? {
        guard let raw = try secrets.read(Self.lastHostKey) else { return nil }
        guard raw.count == 32 else { throw ClientStoreError.corrupt(key: Self.lastHostKey) }
        return raw
    }

    /// nil forgets it.
    public func setLast(hostKey: Data?) throws {
        if let hostKey { try secrets.write(Self.lastHostKey, hostKey) } else { try secrets.delete(Self.lastHostKey) }
    }

    /// Deletes the identity the paired Macs and the last one (the way out of a corrupt store); a new identity is made on next use.
    public func reset() throws {
        try secrets.delete(Self.identityKey)
        try secrets.delete(Self.hostsKey)
        try secrets.delete(Self.lastHostKey)
    }

    public func remove(hostKey: Data) throws {
        try write(try hosts().filter { $0.key != hostKey })
    }

    private func write(_ list: [PairedPeer]) throws {
        try secrets.write(Self.hostsKey, try JSONEncoder().encode(list))
    }
}
