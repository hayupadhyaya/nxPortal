import CryptoKit
import XCTest
@testable import PortalKit

/// The wire as it is today, byte for byte -> `Vectors.swift`.
final class VectorTests: XCTestCase {
    // MARK: control

    /// Forces this file to be updated when a `ControlMessage` case is added (the compiler rejects a missing case).
    private func caseName(_ m: ControlMessage) -> String {
        switch m {
        case .pairStart: "pairStart"
        case .pairChallenge: "pairChallenge"
        case .pairProof: "pairProof"
        case .pairResult: "pairResult"
        case .hello: "hello"
        case .welcome: "welcome"
        case .refuse: "refuse"
        case .ready: "ready"
        case .listRequest: "listRequest"
        case .list: "list"
        case .launch: "launch"
        case .resume: "resume"
        case .quitGame: "quitGame"
        case .gameState: "gameState"
        case .bye: "bye"
        case .artRequest: "artRequest"
        case .art: "art"
        case .liveSettings: "liveSettings"
        case .optionsRequest: "optionsRequest"
        case .options: "options"
        case .setOption: "setOption"
        case .resetOptions: "resetOptions"
        }
    }

    func testControlMessagesMatchPinnedJSON() throws {
        XCTAssertEqual(Set(Samples.control.map(\.name)), Set(Vectors.control.keys), "a sample without a vector, or a vector without a sample")
        for (name, value) in Samples.control {
            let pinned = try XCTUnwrap(Vectors.control[name], name)
            XCTAssertEqual(String(decoding: try value.encoded(), as: UTF8.self), pinned, name)
            XCTAssertEqual(try ControlMessage(decoding: Data(pinned.utf8)), value, name)
        }
        let cases = Set(Samples.control.map { caseName($0.value) })
        XCTAssertEqual(cases.count, 22, "every ControlMessage case has a sample")
    }

    /// Only the removal leaves the value out; a rejected setting names its variable.
    func testASetOptionWithoutAValueHasNoValueKey() throws {
        XCTAssertFalse(try XCTUnwrap(Vectors.control["setOption.remove"]).contains("value"))
        XCTAssertTrue(try XCTUnwrap(Vectors.control["setOption"]).contains("\"value\":\"0.75\""))
        XCTAssertFalse(try XCTUnwrap(Vectors.control["options"]).contains("rejected"))
    }

    func testEnumRawValuesArePinned() {
        XCTAssertEqual(Samples.enumRawValues.map(\.raw), ["phone,tablet,tv,tool", "idle,starting,running,paused"])
    }

    func testHelloWithoutBitrateHasNoBitrateKey() throws {
        let json = try XCTUnwrap(Vectors.control["hello"])
        XCTAssertFalse(json.contains("bitrate"))
        XCTAssertTrue(try XCTUnwrap(Vectors.control["hello.bitrate"]).contains("\"bitrate\":30000000"))
    }

    /// A resuming hello (the key absent) is the hello of before; a library session says `"resume":false`.
    func testOnlyALibraryHelloCarriesTheResumeKey() throws {
        XCTAssertFalse(try XCTUnwrap(Vectors.control["hello"]).contains("resume"))
        XCTAssertFalse(try XCTUnwrap(Vectors.control["hello.bitrate"]).contains("resume"))
        XCTAssertTrue(try XCTUnwrap(Vectors.control["hello.library"]).contains("\"resume\":false"))
    }

    /// Only a hello with a start rate carries `startBps`; every other hello is the hello of before.
    func testOnlyAHelloWithAStartRateCarriesTheStartKey() throws {
        for name in ["hello", "hello.bitrate", "hello.library"] { XCTAssertFalse(try XCTUnwrap(Vectors.control[name]).contains("startBps"), name) }
        XCTAssertTrue(try XCTUnwrap(Vectors.control["hello.start"]).contains("\"startBps\":10000000"))
    }

    /// Only a hello that carries a name has the `name` key; an older hello decodes with none.
    func testOnlyAHelloWithANameCarriesTheNameKey() throws {
        for name in ["hello", "hello.bitrate", "hello.library", "hello.start"] {
            XCTAssertFalse(try XCTUnwrap(Vectors.control[name]).contains("\"name\""), name)
            let decoded = try ControlMessage(decoding: Data(try XCTUnwrap(Vectors.control[name]).utf8))
            guard case let .hello(h) = decoded else { return XCTFail(name) }
            XCTAssertNil(h.name, name)
        }
        let named = try ControlMessage(decoding: Data(try XCTUnwrap(Vectors.control["hello.name"]).utf8))
        guard case let .hello(h) = named else { return XCTFail("hello.name") }
        XCTAssertEqual(h.name, "iPad mini")
    }

    // MARK: datagrams

    func testDatagramBodiesMatchPinnedBytes() throws {
        XCTAssertEqual(Set(Samples.datagrams.map(\.name)), Set(Vectors.datagrams.keys))
        for (name, value) in Samples.datagrams {
            let pinned = try XCTUnwrap(Vectors.datagrams[name], name)
            XCTAssertEqual(value.type, pinned.type, name)
            XCTAssertEqual(value.body().hex, pinned.body, name)
            XCTAssertEqual(try Datagram(type: pinned.type, body: Data(hex: pinned.body)), value, name)
        }
        XCTAssertNotNil(Samples.datagrams.first { $0.name == "hostStats" })
        XCTAssertFalse(Vectors.datagrams.values.contains { $0.type == 0x28 }, "0x28 (ack) is pinned by WireTests.testAckAndRepairBytes, not here")
    }

    func testDatagramHeaderPinned() throws {
        let key = SymmetricKey(data: Samples.bytes(from: 200))
        var sealer = DatagramSealer(key: key, sessionID: 0x0A0B_0C0D)
        let ping = Datagram.ping(clientNs: 0x0102_0304_0506_0708)
        for (counter, want) in Vectors.sealedPing.enumerated() {
            let sealed = try sealer.seal(type: ping.type, body: ping.body())
            XCTAssertEqual(sealed.hex, want, "counter \(counter)")
            XCTAssertEqual(Data(sealed.prefix(16)).hex, String(want.prefix(32)), "clear header")
        }
        var opener = DatagramOpener(key: key, sessionID: 0x0A0B_0C0D)
        let (type, body) = try opener.open(Data(hex: Vectors.sealedPing[0]))
        XCTAssertEqual(type, 0x24)
        XCTAssertEqual(body, ping.body())
    }

    // MARK: tap

    func testTapMessagesMatchPinnedBytes() throws {
        XCTAssertEqual(Set(Samples.tap.map(\.name)), Set(Vectors.tap.keys))
        for (name, value) in Samples.tap {
            let pinned = try XCTUnwrap(Vectors.tap[name], name)
            XCTAssertEqual(value.encoded().hex, pinned, name)
            var framer = TapFramer()
            XCTAssertEqual(try framer.push(Data(hex: pinned)), [value], name)
        }
    }

    /// Both directions: game to Host (audio, ...) and Host to game (config, keyframe, pad, ...) are in `Samples.tap`.
    func testTapRejectsWhatTheCodeRejectsToday() {
        func push(_ hex: String) -> WireError? {
            var f = TapFramer()
            do { _ = try f.push(Data(hex: hex)); return nil } catch { return error as? WireError }
        }
        XCTAssertEqual(push("020000001502"), .malformed, "a Bool byte of 2")
        XCTAssertEqual(push("020000001501"), nil)
        XCTAssertEqual(push("1b0000001300020000000000000000000080bf0000003f000080be00000040"), .malformed, "a motion frame of 2")
        // A type this side does not know is skipped by its length and reported, not an error (tap protocol 2).
        var f = TapFramer()
        var skipped: [UInt8] = []
        XCTAssertEqual(try f.push(Data(hex: "0100000099"), skipped: { skipped.append($0) }).count, 0)
        XCTAssertEqual(skipped, [0x99])
    }

    // MARK: pairing and session keys

    func testPublicKeysFromFixedPrivateKeys() {
        XCTAssertEqual(Samples.clientStatic.publicKey.hex, Vectors.clientPublic)
        XCTAssertEqual(Samples.hostStatic.publicKey.hex, Vectors.hostPublic)
    }

    func testPairingProofKnownAnswer() throws {
        var client = PairingClient(identity: Samples.clientStatic, name: "Test iPad")
        let start = client.start(ephemeral: Samples.clientEphemeral)
        var host = PairingHost(identity: Samples.hostStatic, name: "Test Mac", code: Samples.pairingCode,
                               startedAt: Date(timeIntervalSince1970: 0))
        let challenge = try host.challenge(for: start, ephemeral: Samples.hostEphemeral, salt: Samples.pairingSalt)
        let proof = try client.proof(for: challenge, code: Samples.pairingCode)
        XCTAssertEqual(proof.hex, Vectors.pairingClientProof)
        guard case let .ok(hostProof) = host.verify(proof: proof, at: Date(timeIntervalSince1970: 1)) else { return XCTFail("not ok") }
        XCTAssertEqual(hostProof.hex, Vectors.pairingHostProof)
        XCTAssertEqual(try client.finish(.ok(hostProof: hostProof)).key, Samples.hostStatic.publicKey)
    }

    func testSessionKeysKnownAnswer() throws {
        let hostEph = Samples.hostEphemeral.publicKey.rawRepresentation
        let clientEph = Samples.clientEphemeral.publicKey.rawRepresentation
        let client = try SessionKeys.derive(role: .client, identity: Samples.clientStatic, ephemeral: Samples.clientEphemeral,
                                            peerKey: Samples.hostStatic.publicKey, peerEphemeral: hostEph)
        let host = try SessionKeys.derive(role: .host, identity: Samples.hostStatic, ephemeral: Samples.hostEphemeral,
                                          peerKey: Samples.clientStatic.publicKey, peerEphemeral: clientEph)
        for keys in [client, host] {
            XCTAssertEqual(keys.clientToHostControl.bytes.hex, Vectors.sessionKeys["c2hctl"])
            XCTAssertEqual(keys.hostToClientControl.bytes.hex, Vectors.sessionKeys["h2cctl"])
            XCTAssertEqual(keys.clientToHostMedia.bytes.hex, Vectors.sessionKeys["c2hmedia"])
            XCTAssertEqual(keys.hostToClientMedia.bytes.hex, Vectors.sessionKeys["h2cmedia"])
        }
    }

    // MARK: send-side size

    func testFramerRefusesOversizeOnSend() throws {
        XCTAssertEqual(ControlFramer.maxMessage, 1 << 20)
        let entry = GameEntry(titleID: Samples.titleID, name: "", streamable: true, state: .idle)
        let base = try ControlMessage.list([entry]).encoded().count
        func list(encodedCount: Int) throws -> Data {
            let big = GameEntry(titleID: Samples.titleID, name: String(repeating: "x", count: encodedCount - base), streamable: true, state: .idle)
            let d = try ControlMessage.list([big]).encoded()
            XCTAssertEqual(d.count, encodedCount)
            return d
        }
        let over = try list(encodedCount: ControlFramer.maxMessage + 1)
        XCTAssertThrowsError(try ControlFramer.framed(over)) { XCTAssertEqual($0 as? WireError, .tooLarge) }

        for count in [ControlFramer.maxMessage - 1, ControlFramer.maxMessage] {
            let ok = try list(encodedCount: count)
            let framed = try ControlFramer.framed(ok)
            XCTAssertEqual(framed, ControlFramer.frame(ok), "the same bytes as the non-throwing framer")
            var reader = ControlFramer()
            XCTAssertEqual(try reader.push(framed), [ok])
        }
        var reader = ControlFramer()
        XCTAssertThrowsError(try reader.push(ControlFramer.frame(over))) { XCTAssertEqual($0 as? WireError, .tooLarge) }
    }

    // MARK: redaction

    func testKeyTypesDoNotPrintSecrets() throws {
        let keys = try SessionKeys.derive(role: .client, identity: Samples.clientStatic, ephemeral: Samples.clientEphemeral,
                                          peerKey: Samples.hostStatic.publicKey,
                                          peerEphemeral: Samples.hostEphemeral.publicKey.rawRepresentation)
        let session = SymmetricKey(data: Samples.bytes(from: 200))
        var secrets: [Data] = [Samples.clientStatic.rawPrivateKey, Samples.hostStatic.rawPrivateKey, session.bytes]
        secrets += [keys.clientToHostControl, keys.hostToClientControl, keys.clientToHostMedia, keys.hostToClientMedia].map(\.bytes)

        let values: [(Any, String)] = [
            (Samples.clientStatic, "Identity(<redacted>)"),
            (keys, "SessionKeys(<redacted>)"),
            (PairingHost(identity: Samples.hostStatic, name: "Test Mac", code: Samples.pairingCode, startedAt: Date()), "PairingHost(<redacted>)"),
            (PairingClient(identity: Samples.clientStatic, name: "Test iPad"), "PairingClient(<redacted>)"),
            (StreamSealer(key: session), "StreamSealer(<redacted>)"),
            (StreamOpener(key: session), "StreamOpener(<redacted>)"),
            (DatagramSealer(key: session, sessionID: 1), "DatagramSealer(<redacted>)"),
            (DatagramOpener(key: session, sessionID: 1), "DatagramOpener(<redacted>)"),
        ]
        for (value, want) in values {
            for text in [String(describing: value), String(reflecting: value), dumped(value)] {
                for secret in secrets {
                    XCTAssertFalse(text.contains(secret.hex), "\(want): hex in \(text)")
                    XCTAssertFalse(text.contains(secret.base64EncodedString()), "\(want): base64 in \(text)")
                }
                XCTAssertFalse(text.contains(Samples.pairingCode), "\(want): the pairing code in \(text)")
            }
            XCTAssertEqual(String(describing: value), want)
            XCTAssertEqual(String(reflecting: value), want)
            XCTAssertEqual(Mirror(reflecting: value).children.count, 0, want)
        }
    }

    private func dumped(_ value: Any) -> String { var s = ""; dump(value, to: &s); return s }
}
