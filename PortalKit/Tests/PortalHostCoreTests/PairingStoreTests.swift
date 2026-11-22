#if os(macOS)
import XCTest
import Foundation
import PortalKit
@testable import PortalHostCore

final class PairingStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-s-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testPersists() throws {
        let file = dir.appendingPathComponent("nested/host.json")
        let peer = PairedPeer(key: Identity().publicKey, name: "Tablet")
        let first = try PairingStore(fileURL: file)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        try first.add(peer)
        try first.add(PairedPeer(key: peer.key, name: "Tablet 2"))
        XCTAssertEqual(first.peers.map(\.name), ["Tablet 2"], "same key replaces")
        XCTAssertEqual(first.peers.map(\.key), [peer.key])

        let second = try PairingStore(fileURL: file)
        XCTAssertEqual(second.identity.publicKey, first.identity.publicKey)
        XCTAssertEqual(second.peers, first.peers)
        XCTAssertEqual(try mode(file), 0o600)

        try second.remove(key: peer.key)
        XCTAssertEqual(try PairingStore(fileURL: file).peers, [])
        XCTAssertEqual(try mode(file), 0o600)
    }

    /// The store on a secret store: identity under `host.identity`, peers under `host.peers`; a second store reads both.
    func testSecretsBackedStore() throws {
        let secrets = MemorySecrets()
        let peer = PairedPeer(key: Identity().publicKey, name: "Tablet")
        let first = try PairingStore(secrets: secrets)
        XCTAssertEqual(try secrets.read("host.identity"), first.identity.rawPrivateKey)
        try first.add(peer)
        let stored = try XCTUnwrap(try secrets.read("host.peers"), "the peers are not under host.peers")
        XCTAssertEqual(try JSONDecoder().decode([PairedPeer].self, from: stored).map(\.key), [peer.key])
        let second = try PairingStore(secrets: secrets)
        XCTAssertEqual(second.identity.publicKey, first.identity.publicKey)
        XCTAssertEqual(second.peers.map(\.key), [peer.key])
        XCTAssertEqual(second.peers.map(\.name), ["Tablet"])
        try second.remove(key: peer.key)
        XCTAssertEqual(try PairingStore(secrets: secrets).peers, [])
        XCTAssertNotEqual(try PairingStore(secrets: MemorySecrets()).identity.publicKey, first.identity.publicKey)
    }

    /// A secret store whose identity read is slow, so every concurrent first run sees "nothing stored yet".
    private struct SlowReads: SecretStoring {
        let inner: MemorySecrets
        func read(_ key: String) throws -> Data? {
            let value = try inner.read(key)
            if key == "host.identity" { usleep(30_000) }
            return value
        }
        func write(_ key: String, _ data: Data) throws { try inner.write(key, data) }
        func delete(_ key: String) throws { try inner.delete(key) }
    }

    /// Twenty first runs at once on one secret store end with one identity, the stored one.
    func testConcurrentFirstRunsShareOneIdentity() throws {
        let memory = MemorySecrets()
        let secrets = SlowReads(inner: memory)
        let lock = NSLock()  // guards keys
        nonisolated(unsafe) var keys: [Data] = []  // appended under `lock` only
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            if let store = try? PairingStore(secrets: secrets) { lock.withLock { keys.append(store.identity.publicKey) } }
        }
        XCTAssertEqual(keys.count, 20)
        XCTAssertEqual(Set(keys).count, 1, "\(Set(keys).count) different identities")
        let stored = try Identity(rawPrivateKey: try XCTUnwrap(try memory.read("host.identity")))
        XCTAssertEqual(keys.first, stored.publicKey, "the stores do not hold the stored identity")
    }

    /// An undecodable `host.peers` means no paired devices; the identity stays.
    func testCorruptPeersAreNoDevicesAndTheIdentityStays() throws {
        let secrets = MemorySecrets()
        let first = try PairingStore(secrets: secrets)
        try first.add(PairedPeer(key: Identity().publicKey, name: "Tablet"))
        try secrets.write("host.peers", Data("not json".utf8))
        let second = try PairingStore(secrets: secrets)
        XCTAssertEqual(second.peers, [])
        XCTAssertEqual(second.identity.publicKey, first.identity.publicKey)
        XCTAssertEqual(try secrets.read("host.identity"), first.identity.rawPrivateKey)
    }

    /// An unreadable `host.identity` throws and is left alone: a new identity would orphan every pairing.
    func testCorruptIdentityThrowsAndIsNotReplaced() throws {
        let secrets = MemorySecrets()
        try secrets.write("host.identity", Data([1, 2, 3]))
        XCTAssertThrowsError(try PairingStore(secrets: secrets))
        XCTAssertEqual(try secrets.read("host.identity"), Data([1, 2, 3]))
    }

    /// The file-backed store throws on a corrupt identity too (and, one document, on corrupt peers).
    func testCorruptFileThrows() throws {
        let file = dir.appendingPathComponent("host.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"identity\":\"AQID\",\"peers\":[]}".utf8).write(to: file)
        XCTAssertThrowsError(try PairingStore(fileURL: file))
    }

    // MARK: names -> .claude/host.md § pairing-store

    private func storeWith(_ peers: [PairedPeer], now: Date = Date(timeIntervalSince1970: 5_000)) throws -> (PairingStore, URL) {
        let file = dir.appendingPathComponent("host.json")
        let store = try PairingStore(fileURL: file, now: { now })
        for p in peers { try store.add(p) }
        return (store, file)
    }

    /// A file written before names were kept (no `alias`, `kind`, `added`) loads unchanged.
    func testAFileWrittenBeforeLoadsWithNoAliasKindOrDate() throws {
        let key = Identity().publicKey
        let identity = Identity().rawPrivateKey
        let json = "{\"identity\":\"\(identity.base64EncodedString())\",\"peers\":[{\"key\":\"\(key.base64EncodedString())\",\"name\":\"iPad\"}]}"
        let file = dir.appendingPathComponent("old.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
        let store = try PairingStore(fileURL: file)
        XCTAssertEqual(store.peers, [PairedPeer(key: key, name: "iPad")])
        XCTAssertNil(store.peers[0].alias); XCTAssertNil(store.peers[0].kind); XCTAssertNil(store.peers[0].added)
        try store.setAlias("Den", key: key)  // a write of the old file keeps everything and stays private
        XCTAssertEqual(try mode(file), 0o600)
    }

    /// A kind or date of another type is nil; the pairing itself is not lost.
    func testAnUnreadableOptionalFieldIsNilNotALostPairing() throws {
        let key = Identity().publicKey.base64EncodedString()
        let json = "[{\"key\":\"\(key)\",\"name\":\"iPad\",\"kind\":\"toaster\",\"added\":\"yesterday\",\"alias\":5}]"
        let peers = try JSONDecoder().decode([PairedPeer].self, from: Data(json.utf8))
        XCTAssertEqual(peers.map(\.name), ["iPad"])
        XCTAssertNil(peers[0].kind); XCTAssertNil(peers[0].added); XCTAssertNil(peers[0].alias)
    }

    func testANewKeyGetsTheDateOfItsPairing() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let (store, _) = try storeWith([PairedPeer(key: Identity().publicKey, name: "iPad")], now: now)
        XCTAssertEqual(store.peers[0].added, now)
    }

    /// A re-pair keeps the date, the alias and the place in the file; the device's own name and kind follow the new pairing.
    func testAddOfAKnownKeyKeepsDateAliasAndPlace() throws {
        let a = Identity().publicKey, b = Identity().publicKey
        let early = Date(timeIntervalSince1970: 100)
        let (store, file) = try storeWith([PairedPeer(key: a, name: "iPad", added: early), PairedPeer(key: b, name: "iPad")])
        try store.setAlias("Den", key: a)
        try store.add(PairedPeer(key: a, name: "iPad mini", kind: .tablet))
        XCTAssertEqual(store.peers.map(\.key), [a, b], "the place in the file")
        XCTAssertEqual(store.peers[0].added, early)
        XCTAssertEqual(store.peers[0].alias, "Den")
        XCTAssertEqual(store.peers[0].name, "iPad mini")
        XCTAssertEqual(try PairingStore(fileURL: file).peers, store.peers, "and the file says the same")
    }

    func testUpdateReplacesTheNameAndKindAndKeepsTheAlias() throws {
        let a = Identity().publicKey
        let (store, _) = try storeWith([PairedPeer(key: a, name: "iPad")])
        try store.setAlias("Den", key: a)
        try store.update(key: a, name: "iPad mini", kind: .tablet)
        XCTAssertEqual(store.peers[0].name, "iPad mini")
        XCTAssertEqual(store.peers[0].kind, .tablet)
        XCTAssertEqual(store.peers[0].alias, "Den")
        try store.update(key: a, name: nil, kind: nil)
        XCTAssertEqual(store.peers[0].name, "iPad mini", "nothing given, nothing changed")
        try store.update(key: Identity().publicKey, name: "Nobody", kind: .tv)
        XCTAssertEqual(store.peers.count, 1, "an unknown key adds nothing")
    }

    /// What is stored is cleaned and bounded by the store itself, whoever calls it.
    func testTheStoreCleansAndBoundsWhatItKeeps() throws {
        let a = Identity().publicKey
        let (store, _) = try storeWith([PairedPeer(key: a, name: "iPad")])
        let hostile = "\u{7}" + String(repeating: "x\u{202E}\n", count: 5_000)
        try store.update(key: a, name: hostile, kind: nil)
        XCTAssertLessThanOrEqual(store.peers[0].name.utf8.count, DeviceName.maxBytes)
        XCTAssertEqual(DeviceName.clean(store.peers[0].name), store.peers[0].name)
        try store.update(key: a, name: " \n ", kind: nil)
        XCTAssertNotEqual(store.peers[0].name, "", "a name that cleans to nothing changes nothing")
        try store.setAlias(hostile, key: a)
        XCTAssertLessThanOrEqual(try XCTUnwrap(store.peers[0].alias).utf8.count, DeviceName.maxBytes)
        try store.add(PairedPeer(key: Identity().publicKey, name: hostile))
        XCTAssertLessThanOrEqual(store.peers[1].name.utf8.count, DeviceName.maxBytes)
    }

    func testSetAliasNilRemovesIt() throws {
        let a = Identity().publicKey
        let (store, file) = try storeWith([PairedPeer(key: a, name: "iPad")])
        try store.setAlias("Den", key: a)
        XCTAssertEqual(store.peers[0].alias, "Den")
        try store.setAlias(nil, key: a)
        XCTAssertNil(store.peers[0].alias)
        try store.setAlias("  ", key: a)
        XCTAssertNil(store.peers[0].alias, "an alias that cleans to nothing is none")
        XCTAssertEqual(try mode(file), 0o600)
    }
}
#endif
