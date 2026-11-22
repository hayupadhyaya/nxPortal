import CryptoKit
import Foundation
@testable import PortalKit

/// Fixed inputs for the pinned vectors in `Vectors.swift`. Every value is spelled out so a vector never depends on a random draw.
enum Samples {
    static func bytes(from first: UInt8, count: Int = 32) -> Data { Data((0..<count).map { first &+ UInt8($0) }) }

    static let clientStatic = try! Identity(rawPrivateKey: bytes(from: 1))
    static let hostStatic = try! Identity(rawPrivateKey: bytes(from: 33))
    static let clientEphemeral = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(from: 65))
    static let hostEphemeral = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(from: 97))
    static let pairingSalt = bytes(from: 0xA0, count: 16)
    static let pairingCode = "123456"

    static let k = Data([1, 2, 3, 4])
    static let titleID = "0400486024DEC000"

    /// One value per `ControlMessage` case (four for `hello`, one per `PairResult` and `Refusal` case), by name.
    static let control: [(name: String, value: ControlMessage)] = [
        ("pairStart", .pairStart(PairStart(clientKey: k, clientEphemeral: k, name: "iPad"))),
        ("pairChallenge", .pairChallenge(PairChallenge(hostKey: k, hostEphemeral: k, salt: k, hostName: "Mac"))),
        ("pairProof", .pairProof(k)),
        ("pairResult.ok", .pairResult(.ok(hostProof: k))),
        ("pairResult.wrongCode", .pairResult(.wrongCode(triesLeft: 2))),
        ("pairResult.locked", .pairResult(.locked)),
        ("pairResult.expired", .pairResult(.expired)),
        ("hello", .hello(Hello(version: ProtocolVersion.network, clientKey: k, ephemeral: k, kind: .tv, maxWidth: 3840, maxHeight: 2160, maxFps: 60))),
        ("hello.bitrate", .hello(Hello(version: ProtocolVersion.network, clientKey: k, ephemeral: k, kind: .tablet, maxWidth: 1920, maxHeight: 1080,
                                       maxFps: 60, bitrate: 30_000_000))),
        ("hello.library", .hello(Hello(version: ProtocolVersion.network, clientKey: k, ephemeral: k, kind: .phone, maxWidth: 1920, maxHeight: 1080,
                                       maxFps: 60, resume: false))),
        ("hello.start", .hello(Hello(version: ProtocolVersion.network, clientKey: k, ephemeral: k, kind: .phone, maxWidth: 1920, maxHeight: 1080,
                                     maxFps: 60, bitrate: 20_000_000, startBps: 10_000_000))),
        ("hello.name", .hello(Hello(version: ProtocolVersion.network, clientKey: k, ephemeral: k, kind: .tablet, maxWidth: 1920, maxHeight: 1080,
                                    maxFps: 60, name: "iPad mini"))),
        ("welcome", .welcome(Welcome(ephemeral: k, udpPort: 5000, sessionID: 9))),
        ("refuse.unpaired", .refuse(.unpaired)),
        ("refuse.busy", .refuse(.busy(device: "TV"))),
        ("refuse.version", .refuse(.version(host: ProtocolVersion.network))),
        ("ready", .ready),
        ("listRequest", .listRequest),
        ("list", .list([GameEntry(titleID: titleID, name: "G", streamable: true, state: .idle)])),
        ("launch", .launch(titleID: titleID)),
        ("resume", .resume),
        ("quitGame", .quitGame),
        ("gameState", .gameState(GameState(titleID: titleID, run: .running, reason: nil))),
        ("gameState.paused", .gameState(GameState(titleID: nil, run: .paused, reason: "x"))),
        ("gameState.preparing", .gameState(GameState(titleID: titleID, run: .running, reason: nil, preparing: Preparing(phase: 2, done: 12400, total: 34649)))),
        ("gameState.render", .gameState(GameState(titleID: titleID, run: .running, reason: nil, render: RenderSize(width: 1920, height: 1080, exact: true)))),
        ("gameState.waiting", .gameState(GameState(titleID: titleID, run: .starting, reason: nil, preparing: .waiting))),
        ("bye", .bye()),
        ("bye.takenBy", .bye(takenBy: "TV")),
        ("list.art", .list([GameEntry(titleID: titleID, name: "G", streamable: true, state: .idle, art: ArtRef(hash: "ab", bytes: 1234))])),
        ("artRequest", .artRequest(titleID: titleID, hash: "ab")),
        ("art", .art(titleID: titleID, hash: "ab", index: 1, count: 2, bytes: k)),
        ("art.none", .art(titleID: titleID, hash: "ab", index: 0, count: 0, bytes: Data())),
        ("liveSettings", .liveSettings(LiveSettings(ceilingBps: 80_000_000, panel: .full))),
        ("liveSettings.empty", .liveSettings(LiveSettings(ceilingBps: nil, panel: nil))),
        ("optionsRequest", .optionsRequest(titleID: titleID)),
        ("options", .options(GameOptions(titleID: titleID, settings: [OptionsWireTests.setting()], rejected: nil))),
        ("options.rejected", .options(GameOptions(titleID: titleID, settings: [], rejected: "DM_STREAM"))),
        ("options.full", .options(GameOptions(titleID: titleID, settings: [], rejected: "DM_RENDER_SCALE", full: true))),
        ("setOption", .setOption(titleID: titleID, env: "DM_RENDER_SCALE", value: "0.75")),
        ("setOption.remove", .setOption(titleID: titleID, env: "DM_RENDER_SCALE", value: nil)),
        ("resetOptions", .resetOptions(titleID: titleID)),
    ]

    /// Every state name of `DeviceKind` and `GameRunState` that the control samples above do not reach.
    static let enumRawValues: [(name: String, raw: String)] = [
        ("DeviceKind", DeviceKind.phone.rawValue + "," + DeviceKind.tablet.rawValue + "," + DeviceKind.tv.rawValue + "," + DeviceKind.tool.rawValue),
        ("GameRunState", [GameRunState.idle, .starting, .running, .paused].map(\.rawValue).joined(separator: ",")),
    ]

    static let motion = MotionSample(frame: .switchDevice, acc: SIMD3(0, 0, -1), rot: SIMD3(0.5, -0.25, 2))

    /// Datagram bodies that are stable. `audio` and `video` are left out on purpose.
    // pinned when the transport plan lands: the audio and video datagrams
    static let datagrams: [(name: String, value: Datagram)] = [
        ("input", .input(InputState(seq: 1, player: 0, buttons: 0x8001, lx: -1, ly: 2, rx: -3, ry: 4, motion: nil))),
        ("input.motion", .input(InputState(seq: 2, player: 1, buttons: 3, lx: 0, ly: 0, rx: 0, ry: 0,
                                           motion: MotionSample(frame: .controller, acc: SIMD3(1, 2, 3), rot: SIMD3(-1, -2, -3))))),
        ("keyRequest", .keyRequest(lastGoodFrame: 42)),
        ("ping", .ping(clientNs: 0x0102_0304_0506_0708)),
        ("pong", .pong(clientNs: 1, hostNs: 2)),
        ("nack", .nack(frame: 0xA0B0_C0D0, indices: [0, 1, 0xFFFF])),
        ("nack.all", .nack(frame: 7, indices: [])),
        ("rate", .rate(bitsPerSecond: 62_500_000)),
        ("hostStats", .hostStats(HostStats(framesFromGame: 1, framesSent: 2, framesDropped: 3, resent: 4, rateBps: 100_000_000, sendLateMaxUs: 1234))),
    ]

    /// Tap messages that are stable, both directions. `hello` and `video` are left out on purpose.
    // pinned when the transport plan lands: the tap hello and the tap video message
    static let tap: [(name: String, value: TapMessage)] = [
        ("audio", .audio(captureNs: 99, channels: 2, pcm: Data([1, 2, 3, 4]))),
        ("config", .config(maxWidth: 3840, maxHeight: 2160, maxFps: 60, bitrate: 20_000_000)),
        ("keyframe", .keyframe),
        ("pad", .pad(player: 1, buttons: 0x201, lx: -32767, ly: 32767, rx: 5, ry: -5)),
        ("motion", .motion(player: 0, frame: .switchDevice, acc: motion.acc, rot: motion.rot)),
        ("motion.controller", .motion(player: 2, frame: .controller, acc: SIMD3(1, 2, 3), rot: SIMD3(-1, -2, -3))),
        ("players", .players(mask: 0b101)),
        ("pause.on", .pause(true)),
        ("pause.off", .pause(false)),
        ("quit", .quit),
        ("motionClear", .motionClear(player: 3)),
    ]
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init(hex: String) {
        precondition(hex.count % 2 == 0)
        var out = Data(), i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); out.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        self = out
    }
}

extension SymmetricKey {
    var bytes: Data { withUnsafeBytes { Data($0) } }
}
