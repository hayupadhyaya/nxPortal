#if os(macOS)
import XCTest
import Foundation
import Network
import PortalKit
import PortalTestSupport
import PortalHostCore
import CryptoKit
@testable import PortalClientCore

/// Counts and records what a session's streams deliver.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()  // guards the fields below
    private var _frames: [AssembledFrame] = []
    private var _audio = 0
    private var _states: [GameState] = []
    private var _done = 0
    private var tasks: [Task<Void, Never>] = []

    init(_ s: ClientSession) {
        let f = s.frames, a = s.audio, st = s.states
        tasks = [
            Task { for await x in f { self.lock.withLock { self._frames.append(x) } }; self.lock.withLock { self._done += 1 } },
            Task { for await _ in a { self.lock.withLock { self._audio += 1 } }; self.lock.withLock { self._done += 1 } },
            Task { for await x in st { self.lock.withLock { self._states.append(x) } }; self.lock.withLock { self._done += 1 } },
        ]
    }

    var frames: [AssembledFrame] { lock.withLock { _frames } }
    var audio: Int { lock.withLock { _audio } }
    var states: [GameState] { lock.withLock { _states } }
    /// How many of the three streams have finished.
    var finished: Int { lock.withLock { _done } }
    func stop() { tasks.forEach { $0.cancel() } }
}

/// The values a `Bool` stream delivers, in order.
final class Flags: @unchecked Sendable {
    private let lock = NSLock()  // guards list
    private var list: [Bool] = []
    private var task: Task<Void, Never>?
    init(_ s: AsyncStream<Bool>) { task = Task { for await v in s { self.lock.withLock { self.list.append(v) } } } }
    var values: [Bool] { lock.withLock { list } }
    func stop() { task?.cancel() }
}

/// A TCP listener that accepts and never answers.
final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nxportal.test.silent")
    private let lock = NSLock()  // guards held
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] c in
            c.start(queue: queue)
            lock.withLock { held.append(c) }
        }
        listener.start(queue: queue)
        var bound: UInt16?
        for _ in 0..<400 where bound == nil {
            bound = listener.port.map(\.rawValue).flatMap { $0 == 0 ? nil : $0 }
            if bound == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        guard let bound else { throw ClientError.timeout }
        port = bound
    }

    func stop() { listener.cancel(); lock.withLock { held.forEach { $0.cancel() } } }
}

/// A plain TCP listener on loopback that plays the Host by hand: reads `hello`, writes the scripted control frames.
final class StubHost: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nxportal.test.stub")
    private let lock = NSLock()  // guards held and heard
    private var held: [NWConnection] = []
    private var heard: [Hello] = []
    private(set) var port: UInt16 = 0
    /// Every `hello` that arrived, in order.
    var hellos: [Hello] { lock.withLock { heard } }

    /// `script` returns the clear frames to write when `hello` arrives.
    init(script: @escaping @Sendable () -> [ControlMessage]) async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] c in
            lock.withLock { held.append(c) }
            c.start(queue: queue)
            let box = FramerBox()
            @Sendable func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                    if let data, let payloads = try? box.push(data) {
                        for p in payloads {
                            guard let m = try? ControlMessage(decoding: p), case let .hello(h) = m else { continue }
                            self.lock.withLock { self.heard.append(h) }
                            for out in script() {
                                guard let json = try? out.encoded() else { continue }
                                c.send(content: ControlFramer.frame(json), completion: .contentProcessed { _ in })
                            }
                        }
                    }
                    if error == nil, !done { read() }
                }
            }
            read()
        }
        listener.start(queue: queue)
        var bound: UInt16?
        for _ in 0..<400 where bound == nil {
            bound = listener.port.map(\.rawValue).flatMap { $0 == 0 ? nil : $0 }
            if bound == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        guard let bound else { throw ClientError.timeout }
        port = bound
    }

    func stop() { listener.cancel(); lock.withLock { held.forEach { $0.cancel() } } }

    private final class FramerBox: @unchecked Sendable {
        private let lock = NSLock()  // guards framer
        private var framer = ControlFramer()
        func push(_ d: Data) throws -> [Data] { try lock.withLock { try framer.push(d) } }
    }

    static func welcome() -> ControlMessage {
        .welcome(Welcome(ephemeral: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                         udpPort: UInt16.random(in: 20_000...60_000), sessionID: UInt32.random(in: 1...UInt32.max)))
    }
}

extension ClientSession {
    /// Asks for a key frame and reports how many frames had been yielded at that instant (one actor turn).
    func requestKeyframeCountingShown() -> Int {
        requestKeyframe()
        return tracker.stats.framesShown
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()  // guards on
    private var on = false
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

final class Counts: @unchecked Sendable {
    private let lock = NSLock()  // guards list
    private var list: [Int] = []
    func add(_ n: Int) { lock.withLock { list.append(n) } }
    var values: [Int] { lock.withLock { list } }
}

final class LoopbackTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private var dir: URL!
    private var launcher: FakeLauncher!
    private var service: HostService!
    private var port: UInt16 = 0
    private var sessions: [ClientSession] = []
    private var collectors: [Collector] = []

    override func setUp() async throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-c-" + UUID().uuidString)
        launcher = FakeLauncher()
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        service = try HostService(config: HostConfig(
            name: "Test Host", storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
            launcher: launcher, power: NoPower(), advertise: false, port: 0, extraGames: [fake]))
        port = try await service.start()
    }

    override func tearDown() async throws {
        for c in collectors { c.stop() }
        for s in sessions { await s.close() }
        await service.stop()
        launcher.game?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    private var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    private func session(_ identity: Identity = Identity(), name: String = "Test Client", bitrate: UInt32? = nil,
                         adaptiveRate: Bool = true) -> ClientSession {
        let s = ClientSession(identity: identity, name: name, kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: bitrate,
                              adaptiveRate: adaptiveRate)
        sessions.append(s)
        return s
    }

    private func collect(_ s: ClientSession) -> Collector {
        let c = Collector(s)
        collectors.append(c)
        return c
    }

    private func paired(_ s: ClientSession) async throws -> PairedPeer {
        let code = try await service.beginPairing()
        try await s.connect(to: endpoint)
        return try await s.pair(code: code)
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    /// The bitrate the fake game was configured with once it has been launched.
    private func configuredBitrate(_ s: ClientSession) async throws -> UInt32? {
        let host = try await paired(s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        _ = await waitFor { launcher.game?.received.contains { if case .config = $0 { true } else { false } } ?? false }
        for m in launcher.game?.received ?? [] { if case let .config(_, _, _, bitrate) = m { return bitrate } }
        return nil
    }

    func testBitrateWishReachesTheGame() async throws {
        let bitrate = try await configuredBitrate(session(bitrate: 30_000_000, adaptiveRate: false))
        XCTAssertEqual(bitrate, 30_000_000)
    }

    /// With the rate controller (the default) the game's first config is the controller's start: half the ceiling.
    func testAnAdaptiveSessionStartsTheGameAtHalfItsCeiling() async throws {
        let bitrate = try await configuredBitrate(session(bitrate: 30_000_000))
        XCTAssertEqual(bitrate, 15_000_000)
    }

    func testBitrateWishIsClampedByTheHostMaximum() async throws {
        await service.stop()
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        service = try HostService(config: HostConfig(
            name: "Test Host", storeURL: dir.appendingPathComponent("host2.json"), libraryRoots: [],
            launcher: launcher, power: NoPower(), advertise: false, port: 0, extraGames: [fake], maxBitrate: 40_000_000))
        port = try await service.start()
        let bitrate = try await configuredBitrate(session(bitrate: 150_000_000, adaptiveRate: false))
        XCTAssertEqual(bitrate, 40_000_000)
    }

    func testNoBitrateWishGetsTheHostDefault() async throws {
        let bitrate = try await configuredBitrate(session())
        XCTAssertEqual(bitrate, HostDefaults.bitrate)
    }

    func testPairListLaunchPlay() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        XCTAssertEqual(host.name, "Test Host")
        try await s.open(host: host)
        let games = try await s.list()
        XCTAssertEqual(games, [GameEntry(titleID: fakeID, name: "Fake Game", streamable: true, state: .idle)])
        try await s.launch(titleID: fakeID)
        let first = await waitFor { !c.frames.isEmpty }
        XCTAssertTrue(first, "no frame")
        await sleep(3)
        let stats = await s.stats()
        XCTAssertGreaterThanOrEqual(c.frames.count, 150)
        XCTAssertEqual(stats.framesSkipped, 0)
        XCTAssertEqual(stats.framesShown, c.frames.count)
        XCTAssertTrue((55...65).contains(stats.fps), "fps \(stats.fps)")
        XCTAssertLessThan(stats.p95DelayMs, 50, "p95 \(stats.p95DelayMs)")
        XCTAssertGreaterThanOrEqual(c.audio, 500)
        XCTAssertEqual(c.frames.first?.key, true)
        XCTAssertTrue(c.states.contains { $0.run == .running })
    }

    func testReopenWithoutCode() async throws {
        let id = Identity()
        let first = session(id)
        let host = try await paired(first)
        try await first.open(host: host)
        await first.close()

        let second = session(id)
        try await second.connect(to: endpoint)
        try await second.open(host: host)
        let games = try await second.list()
        XCTAssertEqual(games.count, 1)
    }

    func testRefusalsSurface() async throws {
        let host = try await paired(session())
        let stranger = session()
        try await stranger.connect(to: endpoint)
        do {
            try await stranger.open(host: host)
            XCTFail("opened while unpaired")
        } catch {
            XCTAssertEqual(error as? ClientError, .refused(.unpaired))
        }
    }

    func testWrongCodeSurfaces() async throws {
        _ = try await service.beginPairing()
        let s = session()
        try await s.connect(to: endpoint)
        do {
            _ = try await s.pair(code: "000000x")
            XCTFail("paired with a wrong code")
        } catch {
            guard case .pairing(.wrongCode)? = error as? ClientError else { return XCTFail("\(error)") }
        }
    }

    func testLossRecovers() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        await s.setIncomingDatagramFilter { $0 % 40 != 39 }
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let first = await waitFor { c.frames.count >= 30 }
        XCTAssertTrue(first, "frames \(c.frames.count)")
        await sleep(3)
        let stats = await s.stats()
        // Every 40th datagram lost (resends too): asked for again, repaired byte for byte.
        XCTAssertGreaterThan(stats.nacksSent, 0)
        XCTAssertGreaterThan(stats.framesRepaired, 0)
        XCTAssertGreaterThan(c.frames.count, 100)
        let game = try XCTUnwrap(launcher.game)
        let sent = game.sentVideo
        for f in c.frames {
            guard let original = sent[f.frame] else { continue }  // older than the fake game's 600-frame memory
            XCTAssertEqual(f.data, original, "frame \(f.frame) differs")
        }
        XCTAssertGreaterThan(c.frames.filter { sent[$0.frame] != nil }.count, 50)
    }

    func testCloseDetachesHost() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 5 }
        XCTAssertTrue(streaming)
        let game = try XCTUnwrap(launcher.game)
        await s.close()
        let paused = await waitFor(1) { game.received.contains(.pause(true)) }
        XCTAssertTrue(paused, "no pause(true)")
    }

    func testInputRepeats() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        await s.send(InputState(seq: 0, player: 0, buttons: 1, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil))
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 5 }
        XCTAssertTrue(streaming)
        let game = try XCTUnwrap(launcher.game)
        func pads() -> [UInt64] {
            game.received.compactMap { if case let .pad(0, b, _, _, _, _) = $0 { return b }; return nil }
        }
        let start = pads().count
        await sleep(1)
        let during = Array(pads().dropFirst(start))
        XCTAssertGreaterThanOrEqual(during.count, 60)
        XCTAssertFalse(pads().contains(0), "neutral pad reached the game")
        XCTAssertTrue(during.allSatisfy { $0 == 1 })
    }

    func testOverlappingListsBothReturn() async throws {
        let s = session()
        let host = try await paired(s)
        try await s.open(host: host)
        let counts = Counts()
        // Unstructured, so a call that never returns fails the test instead of hanging it.
        for _ in 0..<2 { Task { if let e = try? await s.list() { counts.add(e.count) } } }
        let both = await waitFor(6) { counts.values.count == 2 }
        XCTAssertTrue(both, "returned: \(counts.values.count) of 2")
        XCTAssertEqual(counts.values, [1, 1])
    }

    func testArtRepliesArriveOnTheirOwnStreamWithNoWaiterAndListStillWorks() async throws {
        let s = session()
        let host = try await paired(s)
        try await s.open(host: host)
        let arts = s.arts
        let got = Task { () -> ArtChunk? in for await c in arts { return c }; return nil }
        try await s.requestArt(titleID: fakeID, hash: String(repeating: "0", count: 64))
        let first = await withTaskGroup(of: ArtChunk?.self) { group in
            group.addTask { await got.value }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); got.cancel(); return nil }
            let r = await group.next() ?? nil
            group.cancelAll()
            return r
        }
        XCTAssertEqual(first, ArtChunk(titleID: fakeID, hash: String(repeating: "0", count: 64), index: 0, count: 0, bytes: Data()))
        let games = try await s.list()
        XCTAssertEqual(games.map(\.titleID), [fakeID])
    }

    /// `options` replies come on their own stream like `art`, with no waiter, and `list` still works beside them; the three
    /// send calls reach the Host (a Host with no `launcher.json` answers with no settings, and refuses a set).
    func testOptionRepliesArriveOnTheirOwnStreamWithNoWaiter() async throws {
        let s = session()
        let host = try await paired(s)
        try await s.open(host: host)
        let replies = s.optionReplies
        let got = Task { () -> [GameOptions] in
            var all: [GameOptions] = []
            for await o in replies { all.append(o); if all.count == 3 { break } }
            return all
        }
        try await s.optionsRequest(titleID: fakeID)
        try await s.setOption(titleID: fakeID, env: "DM_NOT_THERE", value: "1")
        try await s.resetOptions(titleID: fakeID)
        let all = await withTaskGroup(of: [GameOptions].self) { group in
            group.addTask { await got.value }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); got.cancel(); return [] }
            let r = await group.next() ?? []
            group.cancelAll()
            return r
        }
        XCTAssertEqual(all.map(\.titleID), [fakeID, fakeID, fakeID])
        XCTAssertEqual(all.map(\.rejected), [nil, "DM_NOT_THERE", nil])
        let games = try await s.list()
        XCTAssertEqual(games.map(\.titleID), [fakeID])
    }

    func testSilentHostEndsSession() async throws {
        let s = ClientSession(identity: Identity(), name: "Silent", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              silenceTimeout: 3)  // the default is 10 s
        sessions.append(s)
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        // The media path opened first: a session that never hears a datagram ends at 2 s instead (`MediaPathTests`).
        var answered = false
        for _ in 0..<200 where !answered { answered = await s.stats().rttMs > 0; if !answered { await sleep(0.01) } }
        XCTAssertTrue(answered, "no pong arrived")
        await s.setIncomingDatagramFilter { _ in false }
        let start = Date()
        let finished = await waitFor(4) { c.finished == 3 }
        XCTAssertTrue(finished, "streams finished: \(c.finished) after \(Date().timeIntervalSince(start)) s")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 2.5)
    }

    func testIdleSessionStaysOpenOnPongs() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        await sleep(5.5)
        XCTAssertEqual(c.finished, 0, "an idle session ended")
        let games = try await s.list()
        XCTAssertEqual(games.count, 1)
    }

    // MARK: proof, end reason, key request

    func testOpenWaitsForHostProof() async throws {
        let stub = try await StubHost { [StubHost.welcome()] }
        defer { stub.stop() }
        let s = ClientSession(identity: Identity(), name: "Proof", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 0.5)
        sessions.append(s)
        try await s.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: stub.port)!))
        let start = Date()
        do { try await s.open(host: PairedPeer(key: Identity().publicKey, name: "Stub")); XCTFail("opened with no proof") } catch {
            XCTAssertEqual(error as? ClientError, .timeout)
        }
        let waited = Date().timeIntervalSince(start)
        XCTAssertTrue((0.4...5).contains(waited), "waited \(waited) s")
    }

    /// The hello carries the rate controller's start (what the first `rate` says), so the Host knows it at admission;
    /// a fixed rate (no controller) sends no start rate.
    func testTheHelloCarriesTheControllersStartRate() async throws {
        let stub = try await StubHost { [StubHost.welcome()] }
        defer { stub.stop() }
        for (adaptive, want) in [(true, RateController(ceilingBps: 30_000_000).rateBps as UInt32?), (false, nil)] {
            let s = ClientSession(identity: Identity(), name: "Start", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                                  bitrate: 30_000_000, adaptiveRate: adaptive, replyTimeout: 0.3)
            sessions.append(s)
            try await s.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: stub.port)!))
            try? await s.open(host: PairedPeer(key: Identity().publicKey, name: "Stub"))  // no proof comes: it times out
            XCTAssertEqual(stub.hellos.last?.startBps, want, "adaptive \(adaptive)")
            XCTAssertEqual(stub.hellos.last?.bitrate, 30_000_000)
        }
        XCTAssertEqual(stub.hellos.count, 2)
        XCTAssertEqual(stub.hellos.first?.startBps, 15_000_000, "half the ceiling")
    }

    func testCloseDuringProofWait() async throws {
        let stub = try await StubHost { [StubHost.welcome()] }
        defer { stub.stop() }
        let s = ClientSession(identity: Identity(), name: "Proof", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 30)
        sessions.append(s)
        try await s.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: stub.port)!))
        let opening = Task { () -> ClientError? in
            do { try await s.open(host: PairedPeer(key: Identity().publicKey, name: "Stub")); return nil } catch { return error as? ClientError }
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        await s.close()
        let result = await opening.value
        XCTAssertEqual(result, .closed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "open did not return promptly")
        let left = await s.waiters.count
        XCTAssertEqual(left, 0)
    }

    func testClearGameStateBeforeWelcomeIgnored() async throws {
        let stub = try await StubHost {
            [.gameState(GameState(titleID: "SPOOF", run: .running, reason: nil)), .bye(), StubHost.welcome()]
        }
        defer { stub.stop() }
        let s = ClientSession(identity: Identity(), name: "Spoof", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 0.5)
        sessions.append(s)
        let c = collect(s)
        try await s.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: stub.port)!))
        do { try await s.open(host: PairedPeer(key: Identity().publicKey, name: "Stub")); XCTFail("opened with no proof") } catch {
            // The clear `bye` did not end the session (that would be .closed); only the missing proof did.
            XCTAssertEqual(error as? ClientError, .timeout)
        }
        XCTAssertTrue(c.states.isEmpty, "a clear gameState was yielded: \(c.states)")
    }

    func testEndReasons() async throws {
        // close() -> .local
        let a = session()
        let ca = collect(a)
        try await a.open(host: try await paired(a))
        let none = await a.end
        XCTAssertNil(none)
        await a.close()
        let endA = await a.end
        XCTAssertEqual(endA, .local)
        _ = ca

        // a Host that stops answering -> .silence
        let b = ClientSession(identity: Identity(), name: "Quiet", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              silenceTimeout: 0.5)
        sessions.append(b)
        let cb = collect(b)
        try await b.open(host: try await paired(b))
        await b.setIncomingDatagramFilter { _ in false }
        let silent = await waitFor(4) { cb.finished == 3 }
        XCTAssertTrue(silent)
        let endB = await b.end
        XCTAssertEqual(endB, .silence)

        // HostService.stop() -> .hostClosed
        let c = session()
        let cc = collect(c)
        try await c.open(host: try await paired(c))
        await service.stop()
        let stopped = await waitFor(3) { cc.finished == 3 }
        XCTAssertTrue(stopped)
        let endC = await c.end
        XCTAssertEqual(endC, .hostClosed)
    }

    /// The limits the design names: 10 s of silence, 10 pings a second.
    func testTheDefaultsAreTenSecondsOfSilenceAndTenPingsASecond() {
        XCTAssertEqual(ClientSession.defaultSilenceTimeout, 10)
        XCTAssertEqual(ClientSession.pingEveryNs, 100_000_000)
    }

    /// The client's limit, like the Host's in `SessionTests`: live under 1 s, stalled from 1 s, still alive at 9.9 s, ended at 10.1 s.
    func testTheClientsSilenceRuleAtTheEdges() {
        let s: UInt64 = 1_000_000_000, limit = 10 * s
        func state(_ quiet: Double) -> ClientSession.SilenceState {
            ClientSession.silenceState(nowNs: 100 * s + UInt64(quiet * 1e9), lastHeardNs: 100 * s, silenceNs: limit)
        }
        XCTAssertEqual(state(0.9), .live)
        XCTAssertEqual(state(1.1), .stalled)
        XCTAssertEqual(state(9.9), .stalled)
        XCTAssertEqual(state(10.1), .ended)
        XCTAssertEqual(ClientSession.silenceState(nowNs: 5, lastHeardNs: 9, silenceNs: limit), .live, "a clock step back is not silence")
    }

    /// A key frame released from before the stall is not the answer to the refresh: after the recovery, what was
    /// captured (Host clock, mapped by the ping offset) before the recovery moment is dropped, by capture time; a key
    /// frame captured after it comes out. A frame number cannot tell them apart (the Host's numbers go on across the stall).
    func testAKeyFrameCapturedBeforeTheStallIsNotTheAnswerToTheRefresh() async throws {
        let s = session()
        let c = collect(s)
        let flags = Flags(s.stalls)
        defer { flags.stop() }
        try await s.open(host: try await paired(s))
        var rtt = 0.0
        for _ in 0..<300 where rtt == 0 { rtt = await s.stats().rttMs; if rtt == 0 { await sleep(0.01) } }  // the ping offset is known
        XCTAssertGreaterThan(rtt, 0)
        func key(_ n: UInt32, capturedAt ns: UInt64) -> [VideoFragment] {
            FrameSplitter.split(frame: n, key: true, captureNs: ns, width: 64, height: 64, data: Data(count: 3000))
        }
        let before = uptimeNs()
        await s.setIncomingDatagramFilter { _ in false }
        let stalled = await waitFor(3) { flags.values == [true] }
        XCTAssertTrue(stalled)
        await s.setIncomingDatagramFilter(nil)
        let cleared = await waitFor(3) { flags.values == [true, false] }
        XCTAssertTrue(cleared)
        let offset = await s.stats().clockOffsetNs
        for f in key(10, capturedAt: UInt64(Int64(bitPattern: before) + offset)) { await s.video(f, uptimeNs()) }  // made before the stall
        await sleep(0.1)
        XCTAssertEqual(c.frames.map(\.frame), [], "a key frame from before the stall came out as the answer")
        let fresh = UInt64(Int64(bitPattern: uptimeNs()) + offset + 5_000_000)
        for f in key(11, capturedAt: fresh) { await s.video(f, uptimeNs()) }
        let got = await waitFor { c.frames.count == 1 }
        XCTAssertTrue(got)
        XCTAssertEqual(c.frames.map(\.frame), [11])
    }

    /// A Host that goes quiet for 4 s: `stalls` says true after about 1 s, the session stays, and the first thing from
    /// the Host says false and asks for a refresh (once; retried only until the key frame is in).
    func testAQuietHostStallsTheSessionAndAnythingClearsIt() async throws {
        let s = session()
        let c = collect(s)
        let flags = Flags(s.stalls)
        defer { flags.stop() }
        try await s.open(host: try await paired(s))
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 5 }
        XCTAssertTrue(streaming)
        XCTAssertEqual(flags.values, [], "stalled while frames flow")
        let keysBefore = await s.stats().keyRequests
        await s.setIncomingDatagramFilter { _ in false }
        let start = Date()
        let stalled = await waitFor(2) { flags.values == [true] }
        XCTAssertTrue(stalled, "no stall: \(flags.values)")
        XCTAssertTrue((0.9...1.6).contains(Date().timeIntervalSince(start)), "stalled after \(Date().timeIntervalSince(start)) s")
        await sleep(max(0, 4 - Date().timeIntervalSince(start)))
        let end = await s.end
        XCTAssertNil(end, "the session ended in a 4 s stall")
        XCTAssertEqual(flags.values, [true])
        let framesBefore = c.frames.count
        await s.setIncomingDatagramFilter(nil)
        let cleared = await waitFor(2) { flags.values == [true, false] }
        XCTAssertTrue(cleared, "\(flags.values)")
        let flowing = await waitFor(3) { c.frames.count >= framesBefore + 5 }
        XCTAssertTrue(flowing, "no frames after the stall")
        let after = await s.stats()
        XCTAssertTrue((1...3).contains(after.keyRequests - keysBefore), "\(after.keyRequests - keysBefore) key requests for one recovery")
        XCTAssertEqual(flags.values, [true, false])
    }

    /// What the assembler held when the link went quiet is not asked for when it comes back: the stream restarts.
    func testNothingFromBeforeAStallIsAskedForAfterIt() async throws {
        let s = session()
        let flags = Flags(s.stalls)
        defer { flags.stop() }
        try await s.open(host: try await paired(s))
        await s.setIncomingDatagramFilter { _ in false }
        func frags(_ n: UInt32, key: Bool) -> [VideoFragment] {
            FrameSplitter.split(frame: n, key: key, captureNs: 1, width: 64, height: 64, data: Data(count: 5000))
        }
        for f in frags(1, key: true) { await s.video(f, uptimeNs()) }
        for f in frags(2, key: false) where f.index < 2 { await s.video(f, uptimeNs()) }  // the tail of frame 2 never came
        let stalled = await waitFor(3) { flags.values == [true] }
        XCTAssertTrue(stalled)
        let quiet = await s.stats()
        XCTAssertEqual(quiet.nacksSent, 0, "a stalled link asked for something")
        await s.setIncomingDatagramFilter(nil)  // the next datagram from the Host (a pong or hostStats) ends the stall
        let cleared = await waitFor(3) { flags.values == [true, false] }
        XCTAssertTrue(cleared)
        await sleep(0.4)  // past the old frame's asks and give-up
        let later = await s.stats()
        XCTAssertEqual(later.nacksSent, 0, "frame 2, from before the stall, was asked for after it")
        XCTAssertEqual(later.refreshes, 0)
    }

    func testRequestKeyframeYieldsKeyNext() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 30 }
        XCTAssertTrue(streaming)
        let shown = await s.requestKeyframeCountingShown()
        let after = await waitFor { c.frames.count >= shown + 10 }
        XCTAssertTrue(after, "frames \(c.frames.count) after request at \(shown)")
        let next = c.frames[shown...].prefix(10).map { $0 }
        XCTAssertTrue(next[0].key, "frame \(next[0].frame) after the request is not a key frame")
        for (x, y) in zip(next, next.dropFirst()) { XCTAssertEqual(y.frame, x.frame + 1) }
    }

    /// A new game numbers its frames from 0 again: the session starts a fresh stream -> .claude/client.md § session
    func testNewGameRestartsTheVideoStream() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 30 }
        XCTAssertTrue(streaming)
        let statesBefore = c.states.count
        try await s.quitGame()
        let idle = await waitFor(8) { c.states.dropFirst(statesBefore).contains { $0.run == .idle } }
        XCTAssertTrue(idle, "no idle after quit: \(c.states.map(\.run))")
        let before = c.frames.count
        let skippedBefore = await s.stats().framesSkipped
        try await s.launch(titleID: fakeID)
        let more = await waitFor(3) { c.frames.count >= before + 5 }
        XCTAssertTrue(more, "\(c.frames.count - before) frames after the second launch")
        let next = c.frames[before...]
        XCTAssertEqual(next.first?.key, true, "frame \(next.first?.frame ?? 0) after the second launch is not a key frame")
        let skippedAfter = await s.stats().framesSkipped
        XCTAssertLessThanOrEqual(skippedAfter - skippedBefore, 1, "the restart counted as skipped frames")
    }

    /// Loopback has no round trip, so the deltas that sneak in before the key frame are fed by hand.
    func testRequestKeyframeHoldsDeltasUntilKey() async throws {
        let s = ClientSession(identity: Identity(), name: "Hold", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60)
        sessions.append(s)
        let c = collect(s)
        func push(_ n: UInt32, key: Bool) async {
            for f in FrameSplitter.split(frame: n, key: key, captureNs: 1, width: 64, height: 64, data: Data(count: 100)) {
                await s.video(f, 0)
            }
        }
        await push(1, key: true)
        await push(2, key: false)
        await s.requestKeyframe()
        await s.requestKeyframe()  // inside 100 ms: no second request
        await push(3, key: false)
        await push(4, key: false)
        await push(5, key: true)
        await push(6, key: false)
        let got = await waitFor { c.frames.count >= 4 }
        XCTAssertTrue(got)
        XCTAssertEqual(c.frames.map(\.frame), [1, 2, 5, 6])
        let requests = await s.stats().keyRequests
        XCTAssertEqual(requests, 1)
    }

    /// The Host's backlog drop: frame 2 never leaves and is not in the resend store, so a nack finds nothing. Frame 3
    /// must not reach the decoder (it needs 2); the client gives up on 2, asks for a refresh, and after the key frame
    /// frames flow -> .claude/client.md § session
    func testAFrameThatNeverLeftTheHostIsNotSkippedOverAndTheClientAsksForAKeyFrame() async throws {
        let s = ClientSession(identity: Identity(), name: "Gap", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60)
        sessions.append(s)
        let c = collect(s)
        func push(_ n: UInt32, key: Bool) async {
            for f in FrameSplitter.split(frame: n, key: key, captureNs: 1, width: 64, height: 64, data: Data(count: 100)) {
                await s.video(f, uptimeNs())
            }
        }
        await push(1, key: true)
        await push(3, key: false)
        var asked = 0
        for _ in 0..<300 where asked == 0 {
            asked = await s.stats().keyRequests
            if asked == 0 { await sleep(0.001) }
        }
        XCTAssertEqual(c.frames.map(\.frame), [1], "frame 3 reached the decoder without frame 2")
        XCTAssertGreaterThan(asked, 0, "no key frame was asked for")
        await push(4, key: false)
        XCTAssertEqual(c.frames.map(\.frame), [1], "a delta frame reached the decoder while a key frame is awaited")
        await push(5, key: true)
        await push(6, key: false)
        let got = await waitFor { c.frames.count >= 3 }
        XCTAssertTrue(got)
        XCTAssertEqual(c.frames.map(\.frame), [1, 5, 6])
    }

    /// The 8 ms timer is not running (no `open`): only the repair timer can ask. A new stream forgets the hole
    /// -> .claude/client.md § session
    func testAHoleIsAskedForBetweenTicksAndForgottenOnRestart() async throws {
        let s = ClientSession(identity: Identity(), name: "Repair", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60)
        sessions.append(s)
        let c = collect(s)
        func frags(_ n: UInt32, key: Bool) -> [VideoFragment] {
            FrameSplitter.split(frame: n, key: key, captureNs: 1, width: 64, height: 64, data: Data(count: 5000))
        }
        for f in frags(1, key: true) { await s.video(f, uptimeNs()) }
        for f in frags(2, key: false) where f.index != 1 { await s.video(f, uptimeNs()) }
        var asked = 0
        for _ in 0..<200 where asked == 0 {
            asked = await s.stats().nacksSent
            if asked == 0 { await sleep(0.001) }
        }
        XCTAssertEqual(asked, 1, "the hole was not asked for")
        await s.restartVideo()
        let after = await s.stats()
        XCTAssertEqual(after.nacksSent, 0)
        XCTAssertEqual(after.fragmentsAsked, 0)
        await sleep(0.1)  // a negative: past the old frame's retries and give-up
        let later = await s.stats()
        XCTAssertEqual(later.nacksSent, 0, "the old stream's hole was asked for after the restart")
        XCTAssertEqual(later.refreshes, 0)
        let idle = await s.repairTimer == nil
        XCTAssertTrue(idle, "the repair timer outlived the hole")
        for f in frags(0, key: true) { await s.video(f, uptimeNs()) }
        let got = await waitFor { c.frames.count >= 2 }
        XCTAssertTrue(got)
        XCTAssertEqual(c.frames.map(\.frame), [1, 0])
    }

    // MARK: lifetime

    func testSessionDroppedWithoutCloseIsReleased() async throws {
        weak var weakSession: ClientSession?
        do {
            let s = ClientSession(identity: Identity(), name: "Dropped", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60)
            weakSession = s
            let host = try await paired(s)
            try await s.open(host: host)
            try await s.launch(titleID: fakeID)
            let up = await waitFor { self.launcher.game?.received.contains { if case .config = $0 { true } else { false } } == true }
            XCTAssertTrue(up, "game never started")
        }
        let released = await waitFor(2) { weakSession == nil }
        XCTAssertTrue(released, "session still alive after its last reference went")
        let game = try XCTUnwrap(launcher.game)
        let paused = await waitFor(2) { game.received.contains(.pause(true)) }
        XCTAssertTrue(paused, "Host never saw the client leave")
    }

    func testConnectionEndFinishesStreams() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 5 }
        XCTAssertTrue(streaming)
        await service.stop()
        let finished = await waitFor(3) { c.finished == 3 }
        XCTAssertTrue(finished, "streams finished: \(c.finished)")
        do { _ = try await s.list(); XCTFail("list after the connection ended") } catch {
            XCTAssertEqual(error as? ClientError, .closed)
        }
    }

    func testCloseTwiceIsHarmless() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        await s.close()
        await s.close()
        let finished = await waitFor(3) { c.finished == 3 }
        XCTAssertTrue(finished)
        do { try await s.launch(titleID: fakeID); XCTFail("launch after close") } catch {
            XCTAssertEqual(error as? ClientError, .closed)
        }
    }

    func testSilentHostTimesOut() async throws {
        let server = try await SilentServer()
        defer { server.stop() }
        let s = session()
        try await s.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!))
        let start = Date()
        do { _ = try await s.pair(code: "123456"); XCTFail("paired with a silent server") } catch {
            XCTAssertEqual(error as? ClientError, .timeout)
        }
        let waited = Date().timeIntervalSince(start)
        XCTAssertTrue((4.5...6.5).contains(waited), "waited \(waited) s")
    }

    func testKeyRequestsStopAfterKeyFrame() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        let dropAll = Flag()
        await s.setIncomingDatagramFilter { _ in !dropAll.value }
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 30 }
        XCTAssertTrue(streaming)
        let before = c.frames.count
        // 0.3 s: more than the assembler's window of 8 frames, so asking again cannot repair it (0.1 s can).
        dropAll.value = true
        await sleep(0.3)
        dropAll.value = false
        let recovered = await waitFor { c.frames.count >= before + 30 }
        XCTAssertTrue(recovered, "no frames after the gap")
        XCTAssertTrue(c.frames.dropFirst(before).contains { $0.key }, "no key frame after the gap")
        await sleep(0.3)
        let settled = await s.stats().keyRequests
        XCTAssertGreaterThan(settled, 0)
        await sleep(0.6)
        let later = await s.stats().keyRequests
        XCTAssertEqual(later, settled, "key requests continued after a key frame")
    }

    func testDatagramsThatDoNotOpenAreDropped() async throws {
        let s = session()
        let c = collect(s)
        let host = try await paired(s)
        try await s.open(host: host)
        var junk: [Data] = [Data(), Data(repeating: 0x20, count: 16), Data(repeating: 0xAB, count: 40),
                            Data((0..<1200).map { UInt8($0 & 0xFF) }), Data(repeating: 0x20, count: 1201)]
        junk.append(Data([0x20, 0, 0, 0]) + Data(repeating: 0, count: 60))
        for d in junk { await s.datagram(d) }
        await sleep(0.2)
        let stats = await s.stats()
        XCTAssertEqual(stats.framesShown, 0)
        XCTAssertEqual(stats.audioLost, 0)
        XCTAssertEqual(stats.keyRequests, 0)
        XCTAssertEqual(c.audio, 0)
        XCTAssertTrue(c.frames.isEmpty)
        try await s.launch(titleID: fakeID)
        let streaming = await waitFor { c.frames.count >= 5 }
        XCTAssertTrue(streaming, "session unusable after junk")
    }
}
#endif
