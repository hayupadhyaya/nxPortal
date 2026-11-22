#if os(macOS)
import Foundation
import PortalKit
import os

public enum PairingStoreError: Error, Equatable { case system(String, Int32) }

/// The Host's identity and paired devices, in one JSON file (mode 0600) or in a secret store -> .claude/host.md § pairing-store
/// Never logs key material.
public final class PairingStore: @unchecked Sendable {
    private struct File: Codable { var identity: Data; var peers: [PairedPeer] }

    /// Secret store keys.
    static let identityKey = "host.identity", peersKey = "host.peers"

    private enum Backing { case file(URL), secrets(any SecretStoring) }

    private let backing: Backing
    private let lock = NSLock()  // guards file
    private var file: File
    private let ownIdentity: Identity
    /// The wall clock for `added`; a test gives its own.
    private let now: @Sendable () -> Date
    /// A pairing's date is kept across runs, so it is wall time, not the session clock.
    public static let wallClock: @Sendable () -> Date = { Date() }  // wall time: the date a pairing is kept with

    /// Creates the file and a new identity on first use.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = PairingStore.wallClock) throws {
        self.now = now
        backing = .file(fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            file = try JSONDecoder().decode(File.self, from: try Data(contentsOf: fileURL))
            ownIdentity = try Identity(rawPrivateKey: file.identity)
        } else {
            ownIdentity = Identity()
            file = File(identity: ownIdentity.rawPrivateKey, peers: [])
            try Self.write(file, to: fileURL)
        }
    }

    /// Serialises `init(secrets:)` in this process: the first run's read-then-create must not interleave.
    private static let firstRun = NSLock()
    private static let log = Logger(subsystem: "nxportal", category: "store")

    /// Reads (or creates on first use) `host.identity` (the private key) and `host.peers` (JSON) in `secrets`.
    /// An identity that cannot be read throws and is never replaced (a new one would orphan every pairing); peers that cannot be
    /// decoded count as no paired devices. A new identity is read back and that stored value is used, so a store that another
    /// process wrote first wins here too.
    public init(secrets: any SecretStoring, now: @escaping @Sendable () -> Date = PairingStore.wallClock) throws {
        self.now = now
        backing = .secrets(secrets)
        Self.firstRun.lock(); defer { Self.firstRun.unlock() }
        let raw: Data, created: Bool
        if let stored = try secrets.read(Self.identityKey) {
            raw = stored; created = false
        } else {
            let made = Identity().rawPrivateKey
            do { try secrets.write(Self.identityKey, made) } catch {
                guard try secrets.read(Self.identityKey) != nil else { throw error }  // another writer got there first
            }
            raw = try secrets.read(Self.identityKey) ?? made
            created = raw == made
        }
        ownIdentity = try Identity(rawPrivateKey: raw)
        var peers: [PairedPeer] = []
        if let data = try secrets.read(Self.peersKey) {
            if let decoded = try? JSONDecoder().decode([PairedPeer].self, from: data) { peers = decoded } else {
                Self.log.error("the stored list of paired devices cannot be read; treated as empty")
            }
        } else if created {
            try secrets.write(Self.peersKey, try JSONEncoder().encode(peers))
        }
        file = File(identity: raw, peers: peers)
    }

    public var identity: Identity { ownIdentity }
    public var peers: [PairedPeer] { lock.lock(); defer { lock.unlock() }; return file.peers }

    /// Adds a pairing. A key the store has keeps its place, its date (`added`) and its alias, so a re-pair changes no number
    /// the Host shows; a new key gets today's date. The name is cleaned and bounded here, whoever sends it.
    public func add(_ peer: PairedPeer) throws {
        let date = now()
        try update { file in
            var next = peer
            next.name = DeviceName.clean(peer.name) ?? DeviceName.fallback
            next.alias = peer.alias.flatMap(DeviceName.clean)
            if let at = file.peers.firstIndex(where: { $0.key == peer.key }) {
                next.added = file.peers[at].added
                next.alias = file.peers[at].alias
                next.kind = peer.kind ?? file.peers[at].kind
                file.peers[at] = next
            } else {
                next.added = peer.added ?? date
                file.peers.append(next)
            }
        }
    }

    /// What a device's `hello` told: its own name (cleaned and bounded; nothing is changed when it cleans to nothing) and
    /// kind. Never touches `alias`. A key that is not stored changes nothing.
    public func update(key: Data, name: String?, kind: DeviceKind?) throws {
        let cleaned = name.flatMap(DeviceName.clean)
        try update { file in
            guard let at = file.peers.firstIndex(where: { $0.key == key }) else { return }
            if let cleaned { file.peers[at].name = cleaned }
            if let kind { file.peers[at].kind = kind }
        }
    }

    /// The Host's own name for a device (cleaned and bounded); nil, or one that cleans to nothing, removes it.
    public func setAlias(_ alias: String?, key: Data) throws {
        let cleaned = alias.flatMap(DeviceName.clean)
        try update { file in
            guard let at = file.peers.firstIndex(where: { $0.key == key }) else { return }
            file.peers[at].alias = cleaned
        }
    }

    public func remove(key: Data) throws {
        try update { $0.peers.removeAll { $0.key == key } }
    }

    private func update(_ change: (inout File) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var next = file
        change(&next)
        switch backing {
        case let .file(url): try Self.write(next, to: url)
        case let .secrets(secrets): try secrets.write(Self.peersKey, try JSONEncoder().encode(next.peers))
        }
        file = next
    }

    /// Atomic: a 0600 temporary file renamed over the target; parent directory created 0700.
    private static func write(_ file: File, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let data = try JSONEncoder().encode(file)
        let tmp = url.path + ".tmp-\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PairingStoreError.system("open", errno) }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return fsync(fd) == 0
        }
        let e = errno
        close(fd)
        guard ok else { unlink(tmp); throw PairingStoreError.system("write", e) }
        guard rename(tmp, url.path) == 0 else { let e = errno; unlink(tmp); throw PairingStoreError.system("rename", e) }
    }
}
#endif
