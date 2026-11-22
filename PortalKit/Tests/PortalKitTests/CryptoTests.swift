import CryptoKit
import XCTest
@testable import PortalKit

final class CryptoTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pairingPair(code: String = "042917") -> (PairingHost, PairingClient, Identity, Identity) {
        let hostID = Identity(), clientID = Identity()
        return (PairingHost(identity: hostID, name: "Mac", code: code, startedAt: t0),
                PairingClient(identity: clientID, name: "Phone"), hostID, clientID)
    }

    /// First 8 bytes of SHA-256 of the key, 16 lower-case hex digits (the vector is `sha256(00 01 ... 1f)`).
    func testDiscoveryID() {
        XCTAssertEqual(Identity.discoveryID(publicKey: Data(0..<32)), "630dcd2966c43366")
        let id = Identity()
        XCTAssertEqual(id.discoveryID, Identity.discoveryID(publicKey: id.publicKey))
        XCTAssertNotEqual(id.discoveryID, Identity().discoveryID)
    }

    func testPairingRightCode() throws {
        var (host, client, hostID, clientID) = pairingPair()
        let challenge = try host.challenge(for: client.start())
        let proof = try client.proof(for: challenge, code: "042917")
        let result = host.verify(proof: proof, at: t0 + 5)
        let peer = try client.finish(result)
        XCTAssertEqual(peer, PairedPeer(key: hostID.publicKey, name: "Mac"))
        XCTAssertEqual(host.paired, PairedPeer(key: clientID.publicKey, name: "Phone"))
    }

    func testPairingWrongCodeLocks() throws {
        var (host, client, _, _) = pairingPair()
        let challenge = try host.challenge(for: client.start())
        let bad = try client.proof(for: challenge, code: "000000")
        XCTAssertEqual(host.verify(proof: bad, at: t0), .wrongCode(triesLeft: 2))
        XCTAssertEqual(host.verify(proof: bad, at: t0), .wrongCode(triesLeft: 1))
        XCTAssertEqual(host.verify(proof: bad, at: t0), .locked)
        let good = try client.proof(for: challenge, code: "042917")
        XCTAssertEqual(host.verify(proof: good, at: t0), .locked)
        XCTAssertNil(host.paired)
    }

    func testPairingExpires() throws {
        var (host, client, _, _) = pairingPair()
        let challenge = try host.challenge(for: client.start())
        let good = try client.proof(for: challenge, code: "042917")
        XCTAssertEqual(host.verify(proof: good, at: t0 + 121), .expired)
        XCTAssertNil(host.paired)
    }

    func testPairingSingleUse() throws {
        var (host, client, _, _) = pairingPair()
        let challenge = try host.challenge(for: client.start())
        let good = try client.proof(for: challenge, code: "042917")
        guard case .ok = host.verify(proof: good, at: t0) else { return XCTFail("expected ok") }
        XCTAssertEqual(host.verify(proof: good, at: t0), .locked)
    }

    func testPairingHostProofChecked() throws {
        var (host, client, _, _) = pairingPair()
        let challenge = try host.challenge(for: client.start())
        _ = try client.proof(for: challenge, code: "042917")
        XCTAssertThrowsError(try client.finish(.ok(hostProof: Data(count: 32)))) {
            XCTAssertEqual($0 as? PairingError, .hostProofInvalid)
        }
        XCTAssertThrowsError(try client.finish(.locked)) {
            XCTAssertEqual($0 as? PairingError, .refused(.locked))
        }
    }

    func testPairingBadKeyThrows() {
        var (host, _, _, _) = pairingPair()
        let bad = PairStart(clientKey: Data(count: 5), clientEphemeral: Data(count: 5), name: "x")
        XCTAssertThrowsError(try host.challenge(for: bad))
    }

    func testCodeFormat() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let code = PairingCode.generate(using: &rng)
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.utf8.allSatisfy { (48...57).contains($0) })
        }
    }

    func testIdentityRoundTrip() throws {
        let a = Identity()
        let b = try Identity(rawPrivateKey: a.rawPrivateKey)
        XCTAssertEqual(a.publicKey, b.publicKey)
        XCTAssertEqual(a.publicKey.count, 32)
        XCTAssertThrowsError(try Identity(rawPrivateKey: Data(count: 7)))
    }

    private let c = Identity(), h = Identity()
    private let ce = Curve25519.KeyAgreement.PrivateKey(), he = Curve25519.KeyAgreement.PrivateKey()

    private func clientKeys(peerKey: Data) throws -> SessionKeys {
        try SessionKeys.derive(role: .client, identity: c, ephemeral: ce,
                               peerKey: peerKey, peerEphemeral: he.publicKey.rawRepresentation)
    }

    private func hostKeys(identity: Identity) throws -> SessionKeys {
        try SessionKeys.derive(role: .host, identity: identity, ephemeral: he,
                               peerKey: c.publicKey, peerEphemeral: ce.publicKey.rawRepresentation)
    }

    private func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    private func all(_ k: SessionKeys) -> [Data] {
        [k.clientToHostControl, k.hostToClientControl, k.clientToHostMedia, k.hostToClientMedia].map(raw)
    }

    func testSessionKeysAgree() throws {
        let cs = all(try clientKeys(peerKey: h.publicKey))
        XCTAssertEqual(cs, all(try hostKeys(identity: h)))
        XCTAssertEqual(Set(cs).count, 4)
    }

    func testSessionKeysBindStaticKeys() throws {
        let good = all(try clientKeys(peerKey: h.publicKey))
        // Same ephemerals; only the peer static key changes.
        XCTAssertNotEqual(all(try clientKeys(peerKey: Identity().publicKey)), good)
        // A host with another static key does not agree with the client.
        XCTAssertNotEqual(all(try hostKeys(identity: Identity())), good)
    }

    func testStreamSeal() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = StreamSealer(key: key)
        let m1 = try sealer.seal(Data("one".utf8)), m2 = try sealer.seal(Data("two".utf8))
        var opener = StreamOpener(key: key)
        XCTAssertEqual(try opener.open(m1), Data("one".utf8))
        XCTAssertEqual(try opener.open(m2), Data("two".utf8))

        var late = StreamOpener(key: key)
        XCTAssertThrowsError(try late.open(m2)) {
            XCTAssertTrue([.tampered, .replayed].contains($0 as? SealError))
        }
        XCTAssertEqual(try late.open(m1), Data("one".utf8))  // failure did not advance

        var flipped = m1; flipped[0] ^= 1
        var o3 = StreamOpener(key: key)
        XCTAssertThrowsError(try o3.open(flipped)) { XCTAssertEqual($0 as? SealError, .tampered) }
        XCTAssertThrowsError(try o3.open(Data(count: 15))) { XCTAssertEqual($0 as? SealError, .malformed) }
    }

    func testDatagramSeal() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = DatagramSealer(key: key, sessionID: 7)
        let body = Data(repeating: 0xAB, count: 1168)
        let d0 = try sealer.seal(type: 0x20, body: body)
        XCTAssertEqual(d0.count, 1200)
        var opener = DatagramOpener(key: key, sessionID: 7)
        let out = try opener.open(d0)
        XCTAssertEqual(out.type, 0x20)
        XCTAssertEqual(out.body, body)
        XCTAssertThrowsError(try opener.open(d0)) { XCTAssertEqual($0 as? SealError, .replayed) }

        var all = [d0]
        for _ in 1...100 { all.append(try sealer.seal(type: 0x21, body: Data([1, 2, 3]))) }
        var o2 = DatagramOpener(key: key, sessionID: 7)
        for i in [5, 3, 4] { XCTAssertEqual(try o2.open(all[i]).type, 0x21) }
        for i in [5, 3, 4] {
            XCTAssertThrowsError(try o2.open(all[i])) { XCTAssertEqual($0 as? SealError, .replayed) }
        }
        XCTAssertEqual(try o2.open(all[100]).body, Data([1, 2, 3]))
        XCTAssertThrowsError(try o2.open(all[0])) { XCTAssertEqual($0 as? SealError, .replayed) }
        XCTAssertEqual(try o2.open(all[37]).type, 0x21)  // 63 below 100 is still in window
        XCTAssertThrowsError(try o2.open(all[36])) { XCTAssertEqual($0 as? SealError, .replayed) }

        var flipped = all[1]; flipped[1] ^= 1
        var o3 = DatagramOpener(key: key, sessionID: 7)
        XCTAssertThrowsError(try o3.open(flipped)) { XCTAssertEqual($0 as? SealError, .tampered) }
        XCTAssertEqual(try o3.open(all[1]).type, 0x21)  // forgery did not consume the counter

        var other = DatagramOpener(key: key, sessionID: 8)
        XCTAssertThrowsError(try other.open(all[1])) { XCTAssertEqual($0 as? SealError, .wrongSession) }
        XCTAssertThrowsError(try o3.open(Data(count: 31))) { XCTAssertEqual($0 as? SealError, .malformed) }
    }
}
