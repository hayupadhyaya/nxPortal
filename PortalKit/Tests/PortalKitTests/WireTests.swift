import CryptoKit
import XCTest
@testable import PortalKit

final class WireTests: XCTestCase {
    private func chunks(_ d: Data, _ n: Int) -> [Data] {
        stride(from: 0, to: d.count, by: n).map { d.subdata(in: $0..<min($0 + n, d.count)) }
    }

    private var tapSamples: [TapMessage] {
        let acc = SIMD3<Float>(0, 0, -1), rot = SIMD3<Float>(0.5, -0.25, 2)
        let pcm = Data(repeating: 5, count: 960)
        return [
        .hello(version: 2, titleID: "0400486024DEC000", name: "Game"),
        .video(frame: 7, captureNs: 123_456_789_012, width: 1920, height: 1080, mark: .key, token: 0x0100_0000, data: Data([1, 2, 3])),
        .video(frame: 8, captureNs: 5, width: 1280, height: 720, mark: .repair, token: -1, data: Data([4])),
        .video(frame: 9, captureNs: 6, width: 1280, height: 720, mark: .none, token: 0x7F00_0001, data: Data()),
        .audio(captureNs: 99, channels: 2, pcm: pcm),
        .prepare(phase: 2, done: 17, total: 34_649),
        .config(maxWidth: 3840, maxHeight: 2160, maxFps: 60, bitrate: 20_000_000),
        .keyframe,
        .pad(player: 1, buttons: 0x201, lx: -32767, ly: 32767, rx: 5, ry: -5),
        .motion(player: 0, frame: .switchDevice, acc: acc, rot: rot),
        .players(mask: 0b101),
        .pause(true),
        .quit,
        .motionClear(player: 3),
        .ltrAck([0x0100_0005]),
        .ltrAck((0..<16).map { Int32($0) - 3 }),
        .refresh,
        ]
    }

    func testTapRoundTrip() throws {
        var all = Data()
        for m in tapSamples { all.append(m.encoded()) }
        var framer = TapFramer()
        var out: [TapMessage] = []
        for c in chunks(all, 7) { out += try framer.push(c) }
        XCTAssertEqual(out, tapSamples)
    }

    func testTapHelloBytes() {
        let got = TapMessage.hello(version: 1, titleID: "0400486024DEC000", name: "A").encoded()
        var want = Data([0x16, 0, 0, 0, 0x01, 0x01, 0x00])
        want.append(Data("0400486024DEC000".utf8))
        want.append(Data([0x01, 0x00, 0x41]))
        XCTAssertEqual(got, want)
    }

    /// Tap protocol 2 `video`: `frame u32, captureNs u64, width u16, height u16, flags u8, token i32, data` (22 bytes
    /// before the data, the type included), little-endian.
    func testTapVideoBytes() {
        let got = TapMessage.video(frame: 0x0102_0304, captureNs: 0x1112_1314_1516_1718, width: 1280, height: 720,
                                   mark: .repair, token: 0x0100_002A, data: Data([0xAB])).encoded()
        let want: [UInt8] = [23, 0, 0, 0, 0x02, 0x04, 0x03, 0x02, 0x01, 0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
                             0x00, 0x05, 0xD0, 0x02, 0x02, 0x2A, 0x00, 0x00, 0x01, 0xAB]
        XCTAssertEqual([UInt8](got), want)
        let none = TapMessage.video(frame: 0, captureNs: 0, width: 0, height: 0, mark: .none, token: -1, data: Data()).encoded()
        XCTAssertEqual([UInt8](none.suffix(5)), [0x00, 0xFF, 0xFF, 0xFF, 0xFF], "flags 0, token -1")
    }

    /// The flags byte is 0, 1 or 2: 3 (key and repair) and any other bit are malformed, and fatal.
    func testTapVideoFlagsOtherThanKeyOrRepairAreRefused() {
        for flags: UInt8 in [3, 4, 0x80] {
            var m = TapMessage.video(frame: 1, captureNs: 2, width: 3, height: 4, mark: .none, token: 5, data: Data([6])).encoded()
            m[4 + 1 + 4 + 8 + 2 + 2] = flags
            var f = TapFramer()
            XCTAssertThrowsError(try f.push(m), "flags \(flags)") { XCTAssertEqual($0 as? WireError, .malformed) }
        }
    }

    /// `prepare` 0x04 against the tap's pinned bytes: `0a 00 00 00 04 PP DD DD DD DD TT TT TT TT`.
    func testTapPrepareBytes() throws {
        let bytes: [UInt8] = [0x0A, 0, 0, 0, 0x04, 0x02, 0x11, 0x00, 0x00, 0x00, 0x59, 0x87, 0x00, 0x00]
        XCTAssertEqual([UInt8](TapMessage.prepare(phase: 2, done: 17, total: 34_649).encoded()), bytes)
        var f = TapFramer()
        XCTAssertEqual(try f.push(Data(bytes)), [.prepare(phase: 2, done: 17, total: 34_649)])
        var short = TapFramer()
        XCTAssertThrowsError(try short.push(Data([0x09, 0, 0, 0, 0x04, 1, 0, 0, 0, 0, 0, 0, 0]))) {
            XCTAssertEqual($0 as? WireError, .malformed)
        }
    }

    /// `ltrAck` 0x18: `count u8` 1...16, then the tokens (i32); `refresh` 0x19 has no payload. Other sizes are fatal.
    func testTapLtrAckAndRefreshBytes() throws {
        XCTAssertEqual([UInt8](TapMessage.ltrAck([1, -1]).encoded()),
                       [10, 0, 0, 0, 0x18, 2, 1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual([UInt8](TapMessage.refresh.encoded()), [1, 0, 0, 0, 0x19])
        for bad: [UInt8] in [[2, 0, 0, 0, 0x18, 0],                          // count 0
                             [6, 0, 0, 0, 0x18, 2, 1, 0, 0, 0],              // count 2, one token
                             [2, 0, 0, 0, 0x19, 0]] {                        // refresh with a payload
            var f = TapFramer()
            XCTAssertThrowsError(try f.push(Data(bad)), "\(bad)") { XCTAssertEqual($0 as? WireError, .malformed) }
        }
        var w = Data([0x46, 0, 0, 0, 0x18, 17])
        w.append(Data(count: 68))
        var f = TapFramer()
        XCTAssertThrowsError(try f.push(w)) { XCTAssertEqual($0 as? WireError, .malformed) }
    }

    /// A message of a type this side does not know is skipped by its length and reported; the next one is delivered.
    func testTapUnknownTypeIsSkippedAndTheNextMessageDelivered() throws {
        var f = TapFramer()
        var skipped: [UInt8] = []
        var bytes = Data([3, 0, 0, 0, 0x7F, 0xAA, 0xBB])
        bytes.append(TapMessage.keyframe.encoded())
        bytes.append(Data([1, 0, 0, 0, 0x05]))
        bytes.append(TapMessage.prepare(phase: 1, done: 0, total: 0).encoded())
        var out: [TapMessage] = []
        for c in chunks(bytes, 3) { out += try f.push(c) { skipped.append($0) } }
        XCTAssertEqual(out, [.keyframe, .prepare(phase: 1, done: 0, total: 0)])
        XCTAssertEqual(skipped, [0x7F, 0x05])
    }

    func testTapRejects() throws {
        var a = TapFramer()
        XCTAssertThrowsError(try a.push(Data([0xFF, 0xFF, 0xFF, 0xFF]))) { XCTAssertEqual($0 as? WireError, .tooLarge) }
        XCTAssertThrowsError(try a.push(Data([0]))) { XCTAssertEqual($0 as? WireError, .tooLarge) }

        var c = TapFramer()
        var short = TapMessage.pad(player: 1, buttons: 2, lx: 3, ly: 4, rx: 5, ry: 6).encoded()
        short.removeLast()
        short.replaceSubrange(0..<4, with: Data([UInt8(short.count - 4), 0, 0, 0]))
        XCTAssertThrowsError(try c.push(short)) { XCTAssertEqual($0 as? WireError, .malformed) }

        var d = TapFramer()
        XCTAssertThrowsError(try d.push(Data([0, 0, 0, 0]))) { XCTAssertEqual($0 as? WireError, .malformed) }

        var e = TapFramer()
        var extra = TapMessage.keyframe.encoded()
        extra.append(0)
        extra.replaceSubrange(0..<4, with: Data([2, 0, 0, 0]))
        XCTAssertThrowsError(try e.push(extra)) { XCTAssertEqual($0 as? WireError, .malformed) }
    }

    func testDatagramRoundTrip() throws {
        let motion = MotionSample(frame: .controller, acc: SIMD3(1, 2, 3), rot: SIMD3(-1, -2, -3))
        let samples: [Datagram] = [
            .video(VideoFragment(frame: 9, index: 1, count: 3, key: true, captureNs: 5, width: 1280, height: 720, payload: Data([9, 8, 7]))),
            .audio(seq: 4, captureNs: 77, pcm: Data(repeating: 1, count: 960)),
            .input(InputState(seq: 1, player: 0, buttons: 0x8001, lx: -1, ly: 2, rx: -3, ry: 4, motion: nil)),
            .input(InputState(seq: 2, player: 1, buttons: 3, lx: 0, ly: 0, rx: 0, ry: 0, motion: motion)),
            .keyRequest(lastGoodFrame: 42),
            .ping(clientNs: 1),
            .pong(clientNs: 1, hostNs: 2),
            .video(VideoFragment(frame: 10, index: 0, count: 1, key: false, repair: true, captureNs: 6, width: 1280, height: 720, payload: Data([1]))),
            .ack(frame: 0xDEAD_BEEF),
            .repair(lastGoodFrame: 41),
        ]
        for d in samples {
            XCTAssertEqual(try Datagram(type: d.type, body: d.body()), d)
        }
        XCTAssertEqual(samples.map(\.type), [0x20, 0x21, 0x22, 0x22, 0x23, 0x24, 0x25, 0x20, 0x28, 0x2A])
        XCTAssertThrowsError(try Datagram(type: 0x30, body: Data())) { XCTAssertEqual($0 as? WireError, .unknownType(0x30)) }
        XCTAssertThrowsError(try Datagram(type: 0x24, body: Data(count: 7))) { XCTAssertEqual($0 as? WireError, .malformed) }
        let bad = VideoFragment(frame: 0, index: 2, count: 2, key: false, captureNs: 0, width: 1, height: 1, payload: Data())
        XCTAssertThrowsError(try Datagram(type: 0x20, body: Datagram.video(bad).body())) { XCTAssertEqual($0 as? WireError, .malformed) }
    }

    func testNackRoundTrips() throws {
        for n in [0, 1, 64] {
            let d = Datagram.nack(frame: 0xA0B0C0D0, indices: (0..<n).map { UInt16($0 * 997 % 65_536) })
            XCTAssertEqual(d.type, 0x26)
            XCTAssertEqual(d.body().count, 4 + 1 + 2 * n)
            XCTAssertEqual(try Datagram(type: 0x26, body: d.body()), d)
        }
    }

    func testHostStatsRoundTrips() throws {
        let d = Datagram.hostStats(HostStats(framesFromGame: 1, framesSent: 2, framesDropped: 3, resent: 4, rateBps: 100_000_000, sendLateMaxUs: 1234))
        XCTAssertEqual(d.type, 0x29)
        XCTAssertEqual(d.body().count, 24)
        XCTAssertEqual(try Datagram(type: 0x29, body: d.body()), d)
        XCTAssertThrowsError(try Datagram(type: 0x29, body: Data(count: 23))) { XCTAssertEqual($0 as? WireError, .malformed) }
        XCTAssertThrowsError(try Datagram(type: 0x29, body: Data(count: 25))) { XCTAssertEqual($0 as? WireError, .malformed) }
    }

    /// `rate`: the video rate the client asks for, u32, 4 bytes.
    func testRateRoundTrips() throws {
        let d = Datagram.rate(bitsPerSecond: 62_500_000)
        XCTAssertEqual(d.type, 0x27)
        XCTAssertEqual([UInt8](d.body()), [0xA0, 0xAC, 0xB9, 0x03])  // little-endian, as every field
        XCTAssertEqual(try Datagram(type: 0x27, body: d.body()), d)
        XCTAssertThrowsError(try Datagram(type: 0x27, body: Data(count: 3))) { XCTAssertEqual($0 as? WireError, .malformed) }
        XCTAssertThrowsError(try Datagram(type: 0x27, body: Data(count: 5))) { XCTAssertEqual($0 as? WireError, .malformed) }
    }

    func testNackRefusesMoreThan64Indices() {
        var w = Data([1, 0, 0, 0, 65])
        w.append(Data(count: 130))
        XCTAssertThrowsError(try Datagram(type: 0x26, body: w)) { XCTAssertEqual($0 as? WireError, .malformed) }
        // The count must match the bytes that follow.
        XCTAssertThrowsError(try Datagram(type: 0x26, body: Data([1, 0, 0, 0, 2, 0, 0])))
    }

    func testPadButtons() {
        XCTAssertEqual(PadButtons.a.rawValue, 1)
        XCTAssertEqual(PadButtons.zr.rawValue, 1 << 9)
        XCTAssertEqual(PadButtons.down.rawValue, 1 << 15)
        XCTAssertEqual(PadButtons(name: "ZR"), .zr)
        XCTAssertNil(PadButtons(name: "Q"))
    }

    /// The fragment's flags byte (offset 8): 0, 1 key, 2 repair; 3 and other bits are malformed.
    func testVideoFragmentCarriesTheRepairMark() throws {
        let f = VideoFragment(frame: 1, index: 0, count: 1, key: false, repair: true, captureNs: 0, width: 1, height: 1, payload: Data())
        var body = Datagram.video(f).body()
        XCTAssertEqual(body[8], 2)
        XCTAssertEqual(try Datagram(type: 0x20, body: body), .video(f))
        for flags: UInt8 in [3, 4] {
            body[8] = flags
            XCTAssertThrowsError(try Datagram(type: 0x20, body: body)) { XCTAssertEqual($0 as? WireError, .malformed) }
        }
    }

    /// `ack` and `repair`: a u32 frame number each, 4 bytes.
    func testAckAndRepairBytes() throws {
        XCTAssertEqual([UInt8](Datagram.ack(frame: 0x0102_0304).body()), [4, 3, 2, 1])
        XCTAssertEqual([UInt8](Datagram.repair(lastGoodFrame: 7).body()), [7, 0, 0, 0])
        for type: UInt8 in [0x28, 0x2A] {
            XCTAssertThrowsError(try Datagram(type: type, body: Data(count: 3))) { XCTAssertEqual($0 as? WireError, .malformed) }
            XCTAssertThrowsError(try Datagram(type: type, body: Data(count: 5))) { XCTAssertEqual($0 as? WireError, .malformed) }
        }
    }

    /// `load`: the pinned vector (35 bytes, little-endian, flags first), and every datagram code is its own.
    func testLoadBytesAreThePinnedVector() throws {
        let h = HostLoad(gpuPresent: true, gameAlive: true, thermal: 1, pressure: 0, cpuTotal: 412, cpuPerf: 551, cpuEff: 120, gpu: 783,
                         memUsedMiB: 18_330, memTotalMiB: 32_768, gameCpuCentiCores: 160, gameMemMiB: 6_250, gameFpsDeci: 600,
                         frameMeanDeciMs: 167, frameP95DeciMs: 190, frameMaxDeciMs: 410)
        let d = Datagram.load(h)
        let b = [UInt8](d.body())
        XCTAssertEqual(b.count, 35)
        XCTAssertEqual(b[0], 0x03)
        XCTAssertEqual(Array(b[3...4]), [0x9C, 0x01])
        let expected: [UInt8] = [0x03, 0x01, 0x00, 0x9C, 0x01, 0x27, 0x02, 0x78, 0x00, 0x0F, 0x03,
                                 0x9A, 0x47, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x6A, 0x18, 0x00, 0x00,
                                 0x58, 0x02, 0xA7, 0x00, 0xBE, 0x00, 0x9A, 0x01]
        XCTAssertEqual(b, expected)
        XCTAssertEqual(try Datagram(type: d.type, body: d.body()), d)
        XCTAssertThrowsError(try Datagram(type: d.type, body: Data(count: 34))) { XCTAssertEqual($0 as? WireError, .malformed) }
        XCTAssertThrowsError(try Datagram(type: d.type, body: Data(count: 36))) { XCTAssertEqual($0 as? WireError, .malformed) }
    }

    func testLoadWithoutAGPUReadingSendsTheNotAvailableValue() throws {
        let h = HostLoad(gpuPresent: false, gameAlive: false, thermal: 0, pressure: 2, cpuTotal: 1, cpuPerf: 2, cpuEff: 3, gpu: 0,
                         memUsedMiB: 4, memTotalMiB: 5, gameCpuCentiCores: 0, gameMemMiB: 0, gameFpsDeci: 0,
                         frameMeanDeciMs: 0, frameP95DeciMs: 0, frameMaxDeciMs: 0)
        let b = [UInt8](Datagram.load(h).body())
        XCTAssertEqual(b[0], 0x00)
        XCTAssertEqual(Array(b[9...10]), [0xFF, 0xFF])
        XCTAssertEqual(try Datagram(type: Datagram.load(h).type, body: Data(b)), .load(h))
    }

    func testLoadHasItsOwnCodeAmongAllDatagramCodes() {
        let all: [Datagram] = [
            .video(VideoFragment(frame: 0, index: 0, count: 1, key: false, captureNs: 0, width: 1, height: 1, payload: Data())),
            .audio(seq: 0, captureNs: 0, pcm: Data()), .input(InputState(seq: 0, player: 0, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil)),
            .keyRequest(lastGoodFrame: 0), .ping(clientNs: 0), .pong(clientNs: 0, hostNs: 0), .nack(frame: 0, indices: []),
            .rate(bitsPerSecond: 0), .hostStats(HostStats(framesFromGame: 0, framesSent: 0, framesDropped: 0, resent: 0, rateBps: 0)),
            .ack(frame: 0), .repair(lastGoodFrame: 0), .load(HostLoad()),
        ]
        XCTAssertEqual(Set(all.map(\.type)).count, all.count, "every datagram has its own code")
        XCTAssertEqual(Datagram.load(HostLoad()).type, 0x2B)
    }

    func testVideoPayloadFits() {
        let f = VideoFragment(frame: 1, index: 0, count: 1, key: false, captureNs: 0, width: 1, height: 1,
                              payload: Data(count: Wire.maxVideoPayload))
        XCTAssertEqual(Wire.maxVideoPayload, 1147)
        XCTAssertEqual(Datagram.video(f).body().count, 1168)
    }

    func testHelloBitrateRoundTrips() throws {
        let k = Data([1, 2, 3, 4])
        for wish: UInt32? in [nil, 30_000_000] {
            let m = ControlMessage.hello(Hello(version: 2, clientKey: k, ephemeral: k, kind: .tablet, maxWidth: 1920, maxHeight: 1080,
                                               maxFps: 60, bitrate: wish))
            let bytes = try m.encoded()
            XCTAssertEqual(try ControlMessage(decoding: bytes), m)
            guard case let .hello(h) = try ControlMessage(decoding: bytes) else { return XCTFail("not a hello") }
            XCTAssertEqual(h.bitrate, wish)
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self).contains("bitrate"), wish != nil, "key present only with a wish")
        }
    }

    func testHelloWithoutBitrateKeyDecodes() throws {
        let json = #"{"hello":{"_0":{"clientKey":"AQID","ephemeral":"AQID","kind":"tv","maxFps":60,"maxHeight":1080,"maxWidth":1920,"version":1}}}"#
        guard case let .hello(h) = try ControlMessage(decoding: Data(json.utf8)) else { return XCTFail("not a hello") }
        XCTAssertNil(h.bitrate)
        XCTAssertEqual(h.maxWidth, 1920)
    }

    /// `resume: false` opens a library session; the key is absent when nil, and a hello without it decodes nil (resuming).
    func testHelloResumeRoundTripsAndIsAbsentWhenNil() throws {
        let k = Data([1, 2, 3, 4])
        for wish: Bool? in [nil, false, true] {
            let m = ControlMessage.hello(Hello(version: 4, clientKey: k, ephemeral: k, kind: .phone, maxWidth: 1920, maxHeight: 1080,
                                               maxFps: 60, resume: wish))
            let bytes = try m.encoded()
            guard case let .hello(h) = try ControlMessage(decoding: bytes) else { return XCTFail("not a hello") }
            XCTAssertEqual(h.resume, wish)
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self).contains("resume"), wish != nil, "key present only when set")
        }
        let old = #"{"hello":{"_0":{"clientKey":"AQID","ephemeral":"AQID","kind":"tv","maxFps":60,"maxHeight":1080,"maxWidth":1920,"version":4}}}"#
        guard case let .hello(h) = try ControlMessage(decoding: Data(old.utf8)) else { return XCTFail("not a hello") }
        XCTAssertNil(h.resume)
    }

    func testControlRoundTrip() throws {
        let k = Data([1, 2, 3, 4])
        let samples: [ControlMessage] = [
            .pairStart(PairStart(clientKey: k, clientEphemeral: k, name: "iPad")),
            .pairChallenge(PairChallenge(hostKey: k, hostEphemeral: k, salt: k, hostName: "Mac")),
            .pairProof(k),
            .pairResult(.ok(hostProof: k)), .pairResult(.wrongCode(triesLeft: 2)), .pairResult(.locked), .pairResult(.expired),
            .hello(Hello(version: 1, clientKey: k, ephemeral: k, kind: .tv, maxWidth: 3840, maxHeight: 2160, maxFps: 60)),
            .welcome(Welcome(ephemeral: k, udpPort: 5000, sessionID: 9)),
            .refuse(.unpaired), .refuse(.busy(device: "TV")), .refuse(.version(host: 2)),
            .ready, .listRequest,
            .list([GameEntry(titleID: "0400486024DEC000", name: "G", streamable: true, state: .idle)]),
            .launch(titleID: "0400486024DEC000"), .resume, .quitGame,
            .gameState(GameState(titleID: nil, run: .paused, reason: "x")),
            .gameState(GameState(titleID: "0400486024DEC000", run: .running, reason: nil)),
            .bye(), .bye(takenBy: "TV"),
        ]
        var all = Data()
        for m in samples { all.append(ControlFramer.frame(try m.encoded())) }
        var framer = ControlFramer()
        var out: [ControlMessage] = []
        for c in chunks(all, 5) { for p in try framer.push(c) { out.append(try ControlMessage(decoding: p)) } }
        XCTAssertEqual(out, samples)

        var big = ControlFramer()
        XCTAssertThrowsError(try big.push(Data([0, 0, 0x20, 0]))) { XCTAssertEqual($0 as? WireError, .tooLarge) }
        XCTAssertThrowsError(try big.push(Data([1]))) { XCTAssertEqual($0 as? WireError, .tooLarge) }
        var zero = ControlFramer()
        XCTAssertThrowsError(try zero.push(Data([0, 0, 0, 0]))) { XCTAssertEqual($0 as? WireError, .malformed) }
        XCTAssertThrowsError(try ControlMessage(decoding: Data("nope".utf8))) { XCTAssertEqual($0 as? WireError, .malformed) }
    }

    // MARK: render size (network 4)

    func testGameStateWithRenderRoundTripsAndWithoutItIsNil() throws {
        let r = RenderSize(width: 1920, height: 1080, exact: true)
        let m = ControlMessage.gameState(GameState(titleID: "0400486024DEC000", run: .running, reason: nil, render: r))
        let back = try ControlMessage(decoding: try m.encoded())
        XCTAssertEqual(back, m)
        guard case let .gameState(g) = back else { return XCTFail("not a gameState") }
        XCTAssertEqual(g.render, r)
        let old = Data(#"{"gameState":{"_0":{"run":"running","titleID":"0400486024DEC000"}}}"#.utf8)
        guard case let .gameState(h) = try ControlMessage(decoding: old) else { return XCTFail("not a gameState") }
        XCTAssertNil(h.render)
        let text = String(decoding: try ControlMessage.gameState(GameState(titleID: nil, run: .idle, reason: nil)).encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("render"), text)
        XCTAssertEqual(String(decoding: try m.encoded(), as: UTF8.self),
                       #"{"gameState":{"_0":{"render":{"exact":true,"height":1080,"width":1920},"run":"running","titleID":"0400486024DEC000"}}}"#)
    }

    // MARK: preparing (network 4)

    func testGameStateWithPreparingRoundTrips() throws {
        for p in [Preparing(phase: 2, done: 12400, total: 34649), Preparing(phase: 7, done: 3, total: 9), .waiting] {
            let m = ControlMessage.gameState(GameState(titleID: "0400486024DEC000", run: .running, reason: nil, preparing: p))
            let back = try ControlMessage(decoding: try m.encoded())
            XCTAssertEqual(back, m)
            guard case let .gameState(g) = back else { return XCTFail("not a gameState") }
            XCTAssertEqual(g.preparing, p)
        }
    }

    func testGameStateWithoutPreparingDecodesNilAndNeverWritesTheKey() throws {
        let json = Data(#"{"gameState":{"_0":{"run":"running","titleID":"0400486024DEC000"}}}"#.utf8)
        guard case let .gameState(g) = try ControlMessage(decoding: json) else { return XCTFail("not a gameState") }
        XCTAssertNil(g.preparing)
        XCTAssertEqual(g.run, .running)
        let text = String(decoding: try ControlMessage.gameState(GameState(titleID: nil, run: .idle, reason: nil)).encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("preparing"), text)
        let with = try ControlMessage.gameState(GameState(titleID: nil, run: .running, reason: nil,
                                                          preparing: Preparing(phase: 2, done: 12400, total: 34649))).encoded()
        XCTAssertEqual(String(decoding: with, as: UTF8.self),
                       #"{"gameState":{"_0":{"preparing":{"done":12400,"phase":2,"total":34649},"run":"running"}}}"#)
        XCTAssertLessThan(with.count, 120)
    }

    // MARK: artwork (network 4)

    func testAnArtChunkOf48KiBStaysUnder70000BytesSealed() throws {
        let chunk = Data((0..<ArtChunking.chunkBytes).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        XCTAssertEqual(chunk.count, 49_152)
        let m = ControlMessage.art(titleID: "FAKE000000000000", hash: String(repeating: "a", count: 64), index: 3, count: 11, bytes: chunk)
        let json = try m.encoded()
        XCTAssertEqual(try ControlMessage(decoding: json), m)
        var sealer = StreamSealer(key: SymmetricKey(size: .bits256))
        let framed = ControlFramer.frame(try sealer.seal(json))
        XCTAssertLessThan(framed.count, 70_000)
    }

    func testNoSuchArtRoundTrips() throws {
        let none = ControlMessage.art(titleID: "FAKE000000000000", hash: "00", index: 0, count: 0, bytes: Data())
        XCTAssertEqual(try ControlMessage(decoding: try none.encoded()), none)
        let ask = ControlMessage.artRequest(titleID: "FAKE000000000000", hash: String(repeating: "b", count: 64))
        XCTAssertEqual(try ControlMessage(decoding: try ask.encoded()), ask)
        XCTAssertLessThan(try ask.encoded().count, 140)
    }

    func testGameEntryWithoutArtDecodesWithNil() throws {
        let json = #"{"list":{"_0":[{"name":"G","state":"idle","streamable":true,"titleID":"0400486024DEC000"}]}}"#
        guard case let .list(games) = try ControlMessage(decoding: Data(json.utf8)) else { return XCTFail("not a list") }
        XCTAssertNil(games.first?.art)
        let plain = GameEntry(titleID: "T", name: "G", streamable: true, state: .idle)
        XCTAssertFalse(String(decoding: try ControlMessage.list([plain]).encoded(), as: UTF8.self).contains("art"))
        let withArt = GameEntry(titleID: "T", name: "G", streamable: true, state: .idle,
                                art: ArtRef(hash: String(repeating: "c", count: 64), bytes: 1234))
        XCTAssertEqual(try ControlMessage(decoding: try ControlMessage.list([withArt]).encoded()), .list([withArt]))
    }

    func testArtChunkCount() {
        XCTAssertEqual(ArtChunking.count(bytes: 0), 0)
        XCTAssertEqual(ArtChunking.count(bytes: 1), 1)
        XCTAssertEqual(ArtChunking.count(bytes: 49_152), 1)
        XCTAssertEqual(ArtChunking.count(bytes: 49_153), 2)
        XCTAssertEqual(ArtChunking.count(bytes: 512 * 1024), 11)
    }

    // MARK: live settings (network 4)

    func testLiveSettingsRoundTripAndPinnedJSON() throws {
        let full = ControlMessage.liveSettings(LiveSettings(ceilingBps: 80_000_000, panel: .full))
        XCTAssertEqual(try ControlMessage(decoding: try full.encoded()), full)
        XCTAssertEqual(String(decoding: try full.encoded(), as: UTF8.self),
                       #"{"liveSettings":{"_0":{"ceilingBps":80000000,"panel":"full"}}}"#)
        let none = ControlMessage.liveSettings(LiveSettings(ceilingBps: nil, panel: nil))
        XCTAssertEqual(try ControlMessage(decoding: try none.encoded()), none)
        XCTAssertEqual(String(decoding: try none.encoded(), as: UTF8.self), #"{"liveSettings":{"_0":{}}}"#)
        XCTAssertLessThan(try full.encoded().count, 100)
        XCTAssertEqual(PanelLevel.allCases.map(\.rawValue), ["off", "fps", "compact", "full"])
    }
}

// MARK: per-game options (network 4)

final class OptionsWireTests: XCTestCase {
    static func setting(_ env: String = "DM_RENDER_SCALE", kind: String = "range") -> OptionSetting {
        OptionSetting(env: env, kind: kind, section: "Graphics", label: "Render scale", note: "", defaultValue: "1.0", current: "0.75",
                      chosen: true, options: nil, min: 0.5, max: 1.0, step: 0.05, on: nil, off: nil,
                      base: OptionBase(docked: .init(width: 1920, height: 1080), handheld: .init(width: 1280, height: 720)),
                      level: "basic", needs: nil)
    }

    func testTheFourMessagesRoundTrip() throws {
        let id = "0400486024DEC000"
        let all: [ControlMessage] = [
            .optionsRequest(titleID: id),
            .options(GameOptions(titleID: id, settings: [Self.setting()], rejected: nil)),
            .options(GameOptions(titleID: id, settings: [], rejected: "DM_STREAM")),
            .setOption(titleID: id, env: "DM_RENDER_SCALE", value: "0.75"),
            .setOption(titleID: id, env: "DM_RENDER_SCALE", value: nil),
            .resetOptions(titleID: id),
        ]
        for m in all { XCTAssertEqual(try ControlMessage(decoding: try m.encoded()), m) }
    }

    func testAKindThisBuildDoesNotKnowDecodesAndKeepsItsValue() throws {
        let json = #"{"options":{"_0":{"settings":[{"chosen":false,"current":"x","defaultValue":"x","env":"DM_X","kind":"dial","label":"L","note":"","section":"S"}],"titleID":"T"}}}"#
        guard case let .options(o) = try ControlMessage(decoding: Data(json.utf8)) else { return XCTFail("not options") }
        XCTAssertEqual(o.settings.first?.kind, "dial")
        XCTAssertEqual(o.settings.first?.current, "x")
        XCTAssertNil(o.settings.first?.options)
        XCTAssertNil(o.rejected)
    }

    func testOptionalKeysAreAbsentWhenNil() throws {
        let toggle = OptionSetting(env: "DM_FPS_HOLD", kind: "toggle", section: "S", label: "L", note: "", defaultValue: "on", current: "on",
                                   chosen: false, options: nil, min: nil, max: nil, step: nil, on: "on", off: "off", base: nil, level: nil, needs: nil)
        let text = String(decoding: try ControlMessage.options(GameOptions(titleID: "T", settings: [toggle], rejected: nil)).encoded(), as: UTF8.self)
        for key in ["base", "level", "needs", "min", "max", "step", "rejected"] {
            XCTAssertFalse(text.contains("\"\(key)\""), "\(key) in \(text)")
        }
        XCTAssertTrue(text.contains("\"on\":\"on\""))
    }

    func testTwentyFiveSettingsStayUnder40KB() throws {
        let rows = (0..<25).map { i in
            OptionSetting(env: "DM_SETTING_\(i)", kind: "choice", section: "Performance", label: "A label of a setting number \(i)",
                          note: "A note under the label that says a little about it.", defaultValue: "a", current: "a", chosen: false,
                          options: [["a", "First choice"], ["b", "Second choice"], ["c", "Third choice"]],
                          min: nil, max: nil, step: nil, on: nil, off: nil, base: nil, level: i < 5 ? "basic" : nil, needs: nil)
        }
        let data = try ControlMessage.options(GameOptions(titleID: "0400486024DEC000", settings: rows, rejected: nil)).encoded()
        XCTAssertLessThan(data.count, 40_000)
        XCTAssertNoThrow(try ControlFramer.framed(data))
    }

    func testTheSizeIsTheLaunchersTwoNumbers() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let data = try e.encode(OptionBase(docked: .init(width: 1920, height: 1080), handheld: .init(width: 1280, height: 720)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"docked":[1920,1080],"handheld":[1280,720]}"#)
        XCTAssertThrowsError(try JSONDecoder().decode(OptionBase.Size.self, from: Data("[1]".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(OptionBase.Size.self, from: Data("[1,2,3]".utf8)))
    }
}

// MARK: per-game options are bounded on decode

final class OptionsBoundsTests: XCTestCase {
    private let id = "0400486024DEC000"

    private func row(_ extra: String = "", env: String = "DM_X", label: String = "L") -> String {
        #"{"chosen":false,"current":"a","defaultValue":"a","env":"\#(env)","kind":"choice","label":"\#(label)","note":"","section":"S"\#(extra)}"#
    }

    private func options(_ rows: [String], title: String? = nil, rejected: String? = nil) -> Data {
        let r = rejected.map { #","rejected":"\#($0)""# } ?? ""
        return Data(#"{"options":{"_0":{"settings":[\#(rows.joined(separator: ","))],"titleID":"\#(title ?? id)"\#(r)}}}"#.utf8)
    }

    private func assertRefused(_ data: Data, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ControlMessage(decoding: data), what, file: file, line: line) {
            XCTAssertEqual($0 as? WireError, .refused, what, file: file, line: line)
        }
    }

    func testWhatIsWithinTheLimitsDecodes() throws {
        let pairs = (0..<OptionLimits.maxChoices).map { #"["v\#($0)","Label \#($0)"]"# }.joined(separator: ",")
        let big = String(repeating: "x", count: OptionLimits.maxTextBytes)
        let rows = (0..<OptionLimits.maxSettings).map { row(#","options":[\#(pairs)],"min":0,"max":1,"step":0.5,"base":{"docked":[1,100000],"handheld":[100000,1]}"#, env: "DM_R\($0)", label: big) }
        guard case let .options(o) = try ControlMessage(decoding: options(rows)) else { return XCTFail("not options") }
        XCTAssertEqual(o.settings.count, OptionLimits.maxSettings)
    }

    func testAnOverLongTextIsRefused() {
        assertRefused(options([row(label: String(repeating: "x", count: 900_000))]), "a 900 KB label")
        assertRefused(options([row(label: String(repeating: "x", count: OptionLimits.maxTextBytes + 1))]), "a label one byte over")
        let note = String(repeating: "y", count: 5_000)
        assertRefused(options([#"{"chosen":false,"current":"a","defaultValue":"a","env":"DM_X","kind":"choice","label":"L","note":"\#(note)","section":"S"}"#]), "a note")
        assertRefused(options([row(env: "DM_" + String(repeating: "A", count: 62))]), "a name over 64 bytes")
        assertRefused(options([row(#","level":"\#(String(repeating: "b", count: 33))""#)]), "a level over 32 bytes")
        assertRefused(options([row(#","on":"\#(String(repeating: "c", count: 129))""#)]), "a value over 128 bytes")
        assertRefused(options([row()], rejected: String(repeating: "R", count: 65)), "a rejected echo over 64 bytes")
    }

    func testTooManyRowsOrChoicesAreRefused() {
        assertRefused(options((0...OptionLimits.maxSettings).map { row(env: "DM_R\($0)") }), "201 settings")
        assertRefused(options((0..<100_000).map { _ in row() }), "100000 settings")
        let many = (0..<100_000).map { #"["v\#($0)","l"]"# }.joined(separator: ",")
        assertRefused(options([row(#","options":[\#(many)]"#)]), "100000 choices")
        let one = (0...OptionLimits.maxChoices).map { #"["v\#($0)","l"]"# }.joined(separator: ",")
        assertRefused(options([row(#","options":[\#(one)]"#)]), "65 choices")
        assertRefused(options([row(#","options":[["a","b","c"]]"#)]), "a pair of three")
        assertRefused(options([row(#","options":[["a"]]"#)]), "a pair of one")
    }

    func testNumbersMustBeFiniteAndOrdered() {
        assertRefused(options([row(#","min":1,"max":0,"step":0.1"#)]), "a reversed range")
        assertRefused(options([row(#","min":0,"max":1,"step":0"#)]), "a step of 0")
        assertRefused(options([row(#","min":0,"max":1,"step":-0.1"#)]), "a negative step")
        XCTAssertThrowsError(try ControlMessage(decoding: options([row(#","min":0,"max":1e999,"step":0.1"#)])), "an infinite bound")
        XCTAssertThrowsError(try ControlMessage(decoding: options([row(#","min":NaN"#)])), "NaN is not JSON")
        for size in ["[0,1]", "[1,0]", "[-1,5]", "[100001,1]", "[1,100001]"] {
            assertRefused(options([row(#","base":{"docked":\#(size),"handheld":[1,1]}"#)]), "size \(size)")
        }
    }

    func testAControlCharacterIsRefused() {
        assertRefused(options([row(label: #"A\nB"#)]), "a line break in a label")
        assertRefused(options([row(label: #"A\u0000B"#)]), "a NUL in a label")
        assertRefused(options([row(label: #"\u001b[0m"#)]), "an escape in a label")
        assertRefused(options([row(#","on":"a\nb""#)]), "a line break in a value")
        assertRefused(options([row(#","options":[["a\u0000","b"]]"#)]), "a NUL in a choice's value")
        assertRefused(options([row(env: #"DM_X\nY"#)]), "a line break in a name")
    }

    func testATitleThatIsNotATitleIDIsRefusedInAllFourMessages() {
        for bad in ["", String(repeating: "T", count: 33), "../x", "a b", "T\\u0000", String(repeating: "T", count: 900_000)] {
            assertRefused(options([], title: bad), "options \(bad.prefix(8))")
            assertRefused(Data(#"{"optionsRequest":{"titleID":"\#(bad)"}}"#.utf8), "optionsRequest \(bad.prefix(8))")
            assertRefused(Data(#"{"setOption":{"env":"DM_X","titleID":"\#(bad)","value":"1"}}"#.utf8), "setOption \(bad.prefix(8))")
            assertRefused(Data(#"{"resetOptions":{"titleID":"\#(bad)"}}"#.utf8), "resetOptions \(bad.prefix(8))")
        }
    }

    func testASetOptionIsBoundedOnTheWayIn() throws {
        assertRefused(Data(#"{"setOption":{"env":"\#(String(repeating: "D", count: 900_000))","titleID":"\#(id)"}}"#.utf8), "a 900 KB name")
        assertRefused(Data(#"{"setOption":{"env":"DM_X","titleID":"\#(id)","value":"\#(String(repeating: "1", count: 129))"}}"#.utf8), "a value over 128 bytes")
        // Not a refusal: a name or value that is the wrong KIND of text is the Host's to answer with `rejected`.
        XCTAssertNoThrow(try ControlMessage(decoding: Data(#"{"setOption":{"env":"PATH","titleID":"\#(id)","value":"a\nb"}}"#.utf8)))
    }

    func testARefusedMessageIsNotMalformed() {
        XCTAssertThrowsError(try ControlMessage(decoding: Data(#"{"options":{"_0":{"settings":"no","titleID":"T"}}}"#.utf8))) {
            XCTAssertEqual($0 as? WireError, .malformed, "wrong shape is still malformed: it ends the session")
        }
    }

    // MARK: hello, pairStart and launch are bounded on decode

    private func hello(key: Data, name: String?) -> Data {
        try! ControlMessage.hello(Hello(version: 4, clientKey: key, ephemeral: Data(count: 32), kind: .phone, maxWidth: 1920,
                                        maxHeight: 1080, maxFps: 60, name: name)).encoded()
    }

    /// A key longer than a Curve25519 key ends the connection; a name is cut to the device-name limits at a character boundary.
    func testAHelloAndAPairStartAreBoundedOnTheWayIn() throws {
        XCTAssertThrowsError(try ControlMessage(decoding: hello(key: Data(count: 33), name: nil))) {
            XCTAssertEqual($0 as? WireError, .malformed)
        }
        let long = String(repeating: "é", count: 900)
        guard case let .hello(h) = try ControlMessage(decoding: hello(key: Data(count: 32), name: long)) else { return XCTFail() }
        XCTAssertEqual(h.name, String(repeating: "é", count: DeviceName.maxCharacters))
        let wide = String(repeating: "😀", count: 900)  // 4 bytes each: the byte limit cuts first
        guard case let .hello(w) = try ControlMessage(decoding: hello(key: Data(count: 32), name: wide)) else { return XCTFail() }
        XCTAssertEqual(w.name, String(repeating: "😀", count: DeviceName.maxBytes / 4))
        let pair = try ControlMessage.pairStart(PairStart(clientKey: Data(count: 32), clientEphemeral: Data(count: 64), name: "x")).encoded()
        XCTAssertThrowsError(try ControlMessage(decoding: pair)) { XCTAssertEqual($0 as? WireError, .malformed) }
        let named = try ControlMessage.pairStart(PairStart(clientKey: Data(count: 32), clientEphemeral: Data(count: 32), name: long)).encoded()
        guard case let .pairStart(p) = try ControlMessage(decoding: named) else { return XCTFail() }
        XCTAssertEqual(p.name.count, DeviceName.maxCharacters)
    }

    /// A launch of something that is not a title ID is refused (ignored; the session goes on), so no answer echoes it.
    func testALaunchOfWhatIsNotATitleIDIsRefused() throws {
        for bad in ["", String(repeating: "T", count: 33), "../x", String(repeating: "T", count: 900_000)] {
            assertRefused(Data(#"{"launch":{"titleID":"\#(bad)"}}"#.utf8), "launch \(bad.prefix(8))")
        }
        XCTAssertEqual(try ControlMessage(decoding: Data(#"{"launch":{"titleID":"\#(id)"}}"#.utf8)), .launch(titleID: id))
    }
}

final class RenderFitTests: XCTestCase {
    private func fit(_ w: UInt16, _ h: UInt16, _ cw: UInt16 = 1920, _ ch: UInt16 = 1080) -> Bool {
        RenderSize.fitted(width: w, height: h, capWidth: cw, capHeight: ch).exact
    }

    /// Exact only when neither side reaches its cap: a fitted picture that has a side at the cap may have been scaled down.
    func testOnlyAPictureUnderTheCapOnBothSidesIsExact() {
        XCTAssertTrue(fit(1280, 720))
        XCTAssertFalse(fit(1920, 1080), "the game's size or a scaled one: not told apart")
        XCTAssertFalse(fit(1728, 1080), "a 16:10 game fitted by height")
        XCTAssertFalse(fit(1440, 1080), "a 4:3 game fitted by height")
        XCTAssertFalse(fit(1920, 800), "an ultrawide fitted by width")
        XCTAssertFalse(fit(1918, 1078), "within the fit's even rounding of the cap")
        XCTAssertTrue(fit(1916, 1076))
        XCTAssertFalse(fit(1000, 1080), "one side at the cap is enough")
    }
}
