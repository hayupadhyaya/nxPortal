import XCTest
import PortalKit
@testable import PortalPlayer

final class ClientStoreTests: XCTestCase {
    func testIdentityStableAcrossStores() throws {
        let secrets = MemorySecrets()
        let a = try ClientStore(secrets: secrets).identity()
        let b = try ClientStore(secrets: secrets).identity()
        XCTAssertEqual(a.publicKey, b.publicKey)
        XCTAssertEqual(try secrets.read("identity")?.count, 32)
    }

    func testSaveSameKeyReplacesAndRemoveDeletes() throws {
        let store = ClientStore(secrets: MemorySecrets())
        let key = Identity().publicKey, other = Identity().publicKey
        try store.save(host: PairedPeer(key: key, name: "Old Name"))
        try store.save(host: PairedPeer(key: other, name: "Other"))
        try store.save(host: PairedPeer(key: key, name: "New Name"))
        XCTAssertEqual(try store.hosts(), [PairedPeer(key: other, name: "Other"), PairedPeer(key: key, name: "New Name")])
        try store.remove(hostKey: key)
        XCTAssertEqual(try store.hosts(), [PairedPeer(key: other, name: "Other")])
    }

    func testNoHostsAtFirst() throws {
        XCTAssertEqual(try ClientStore(secrets: MemorySecrets()).hosts(), [])
    }

    func testCorruptIdentityThrowsAndIsKept() throws {
        let secrets = MemorySecrets()
        try secrets.write("identity", Data([1, 2, 3]))
        XCTAssertThrowsError(try ClientStore(secrets: secrets).identity()) {
            XCTAssertEqual($0 as? ClientStoreError, .corrupt(key: "identity"))
        }
        XCTAssertEqual(try secrets.read("identity"), Data([1, 2, 3]), "a corrupt identity was replaced")
    }

    func testCorruptHostsThrowAndAreKept() throws {
        let secrets = MemorySecrets()
        try secrets.write("hosts", Data("not json".utf8))
        let store = ClientStore(secrets: secrets)
        XCTAssertThrowsError(try store.hosts()) { XCTAssertEqual($0 as? ClientStoreError, .corrupt(key: "hosts")) }
        XCTAssertThrowsError(try store.save(host: PairedPeer(key: Identity().publicKey, name: "Mac")))
        XCTAssertEqual(try secrets.read("hosts"), Data("not json".utf8), "corrupt hosts were replaced")
    }

    func testResetClearsCorruptStore() throws {
        let secrets = MemorySecrets()
        try secrets.write("identity", Data([1, 2, 3]))
        try secrets.write("hosts", Data("not json".utf8))
        let store = ClientStore(secrets: secrets)
        XCTAssertThrowsError(try store.identity())
        try store.reset()
        let id = try store.identity()
        XCTAssertEqual(try store.identity().publicKey, id.publicKey)
        XCTAssertEqual(try store.hosts(), [])
    }

    func testMemorySecretsDelete() throws {
        let secrets = MemorySecrets()
        try secrets.write("k", Data([9]))
        try secrets.delete("k")
        XCTAssertNil(try secrets.read("k"))
        try secrets.delete("k")  // absent: harmless
    }

    func testLastHostRoundTripsAndClears() throws {
        let store = ClientStore(secrets: MemorySecrets())
        XCTAssertNil(try store.lastHostKey())
        let key = Identity().publicKey
        try store.setLast(hostKey: key)
        XCTAssertEqual(try store.lastHostKey(), key)
        try store.setLast(hostKey: nil)
        XCTAssertNil(try store.lastHostKey())
    }

    func testLastHostOfTheWrongLengthIsCorrupt() throws {
        let secrets = MemorySecrets()
        try secrets.write("lastHost", Data([1, 2, 3]))
        XCTAssertThrowsError(try ClientStore(secrets: secrets).lastHostKey()) { XCTAssertEqual($0 as? ClientStoreError, .corrupt(key: "lastHost")) }
    }

    func testResetClearsTheLastHost() throws {
        let store = ClientStore(secrets: MemorySecrets())
        try store.setLast(hostKey: Identity().publicKey)
        try store.reset()
        XCTAssertNil(try store.lastHostKey())
    }
}
