#if os(macOS)
import XCTest
import Foundation
import PortalKit
import PortalTestSupport
@testable import PortalHostCore

final class RecordingPower: PowerHolding, @unchecked Sendable {
    private let lock = NSLock()  // guards values
    private var values: [Bool] = []
    func set(_ awake: Bool) { lock.lock(); values.append(awake); lock.unlock() }
    var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

/// A game that stays alive and never connects.
final class SilentLauncher: GameLaunching, @unchecked Sendable {
    private let lock = NSLock()  // guards _terminated
    private var _terminated = false
    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return _terminated }
    fileprivate func markTerminated() { lock.lock(); _terminated = true; lock.unlock() }

    func launch(titleID: String, socketPath: String) async throws -> any RunningGame { SilentGame(owner: self) }
}

private struct SilentGame: RunningGame {
    let owner: SilentLauncher
    func terminate() async { owner.markTerminated() }
    func waitForExit() async -> Int32 {
        while !owner.terminated { try? await Task.sleep(nanoseconds: 10_000_000) }
        return 15
    }
}

/// `FakeGame`s whose process exit is decided by the test: `reportExit` ends the process while its game
/// may stay connected; `terminate()` is recorded and ends the process only when `obeyTerminate`.
final class DetachedLauncher: GameLaunching, @unchecked Sendable {
    private let lock = NSLock()  // guards every var below
    private var _games: [FakeGame] = []
    private var _exited: Set<Int> = []
    private var _terminations = 0
    var obeyTerminate = false

    var games: [FakeGame] { lock.lock(); defer { lock.unlock() }; return _games }
    var terminations: Int { lock.lock(); defer { lock.unlock() }; return _terminations }
    func reportExit(_ index: Int) { lock.lock(); _exited.insert(index); lock.unlock() }
    fileprivate func exited(_ index: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return _exited.contains(index) }
    fileprivate func terminated(_ index: Int) {
        lock.lock(); _terminations += 1; if obeyTerminate { _exited.insert(index) }; lock.unlock()
    }

    private func add(_ g: FakeGame) -> Int { lock.lock(); defer { lock.unlock() }; _games.append(g); return _games.count - 1 }

    func launch(titleID: String, socketPath: String) async throws -> any RunningGame {
        let g = FakeGame(socketPath: socketPath, titleID: titleID, name: "Fake Game")
        let index = add(g)
        Task { try? await g.run() }
        return DetachedGame(owner: self, index: index)
    }
}

private struct DetachedGame: RunningGame {
    let owner: DetachedLauncher
    let index: Int
    func terminate() async { owner.terminated(index) }
    func waitForExit() async -> Int32 {
        while !owner.exited(index) { try? await Task.sleep(nanoseconds: 10_000_000) }
        return 137
    }
}

/// Lines a stream delivered, in order.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()  // guards lines
    private var lines: [String] = []
    func add(_ l: String) { lock.withLock { lines.append(l) } }
    var all: [String] { lock.withLock { lines } }
}

/// What `sessionEnds` yielded.
final class StatusEnds: @unchecked Sendable {
    private let lock = NSLock()  // guards items
    private var items: [SessionEndReport] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<SessionEndReport>) {
        task = Task { [weak self] in for await r in stream { self?.lock.withLock { self?.items.append(r) } } }
    }
    deinit { task?.cancel() }
    var all: [SessionEndReport] { lock.withLock { items } }
    func wait(timeout: TimeInterval = 5, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return cond()
    }
}

final class HostServiceTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private var dir: URL!
    private var launcher: FakeLauncher!
    private var power: RecordingPower!
    private var service: HostService!
    private var port: UInt16 = 0
    private var peers: [ScriptedPeer] = []

    override func setUp() async throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-h-" + UUID().uuidString)
        launcher = FakeLauncher()
        power = RecordingPower()
        service = try makeService()
        port = try await service.start()
    }

    override func tearDown() async throws {
        for p in peers { p.close() }
        await service.stop()
        launcher.game?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeService(startTimeout: TimeInterval = 600, unadmittedTimeout: TimeInterval = 10,
                             clock: (@Sendable () -> Date)? = nil, extraGames: [GameApp] = []) throws -> HostService {
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        var config = HostConfig(
            name: "Test Host", storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
            launcher: launcher, power: power, advertise: false, port: 0, extraGames: [fake] + extraGames,
            startTimeout: startTimeout)
        config.silenceTimeout = 3  // these tests wait for the silence detach; the default is 10 s
        config.unadmittedTimeout = unadmittedTimeout
        if let clock { config.clock = clock }
        return try HostService(config: config)
    }

    // MARK: helpers

    private func peer(_ name: String, like other: ScriptedPeer? = nil) -> ScriptedPeer {
        let p = ScriptedPeer(identity: other?.identity ?? Identity(), name: name)
        if let key = other?.hostKey { p.trust(hostKey: key) }
        peers.append(p)
        return p
    }

    /// Connected and paired; the connection stays open in the clear.
    private func pairedPeer(_ name: String) async throws -> ScriptedPeer {
        let code = try await service.beginPairing()
        let p = peer(name)
        try p.connect(port: port)
        let result = try await p.pair(code: code)
        guard case .ok = result else { throw PeerError.pairing(result) }
        return p
    }

    private func livePeer(_ name: String) async throws -> ScriptedPeer {
        let p = try await pairedPeer(name)
        try await p.open(port: port)
        return p
    }

    private var tapLog: [TapMessage] { launcher.game?.received ?? [] }

    private func waitGame(timeout: TimeInterval = 5, _ cond: @escaping ([TapMessage]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(tapLog) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond(tapLog)
    }

    /// `launch`, then the `running` state and `frames` assembled frames.
    @discardableResult
    private func launchAndStream(_ p: ScriptedPeer, frames: Int = 5) async throws -> FakeGame {
        let before = p.received.count
        p.send(.launch(titleID: fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running, "no running state")
        let streaming = await p.wait { p.received.count >= before + frames }
        XCTAssertTrue(streaming, "frames \(p.received.count - before)")
        return try XCTUnwrap(launcher.game)
    }

    private func pads(_ log: [TapMessage]) -> [UInt64] {
        log.compactMap { if case let .pad(0, buttons, _, _, _, _) = $0 { return buttons }; return nil }
    }

    private func count(_ m: TapMessage, in log: [TapMessage]) -> Int { log.filter { $0 == m }.count }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    // MARK: control

    func testPairThenHello() async throws {
        let p = try await pairedPeer("Phone")
        guard case .welcome? = await p.hello() else { return XCTFail("no welcome") }
        try p.ready()
        p.send(.listRequest)
        guard case let .list(entries)? = await p.next({ if case .list = $0 { true } else { false } }) else {
            return XCTFail("no list")
        }
        XCTAssertEqual(entries, [GameEntry(titleID: fakeID, name: "Fake Game", streamable: true, state: .idle)])
    }

    func testUnpairedRefused() async throws {
        let p = peer("Stranger")
        try p.connect(port: port)
        let reply = await p.hello()
        XCTAssertEqual(reply, .refuse(.unpaired))
        let closed = await p.waitClosed()
        XCTAssertTrue(closed)
    }

    func testWrongVersionRefused() async throws {
        let p = try await pairedPeer("Phone")
        let reply = await p.hello(version: ProtocolVersion.network + 1)
        XCTAssertEqual(reply, .refuse(.version(host: ProtocolVersion.network)))
        let closed = await p.waitClosed()
        XCTAssertTrue(closed)
    }

    func testAVersion2HelloIsRefused() async throws {
        let p = try await pairedPeer("Phone")
        let reply = await p.hello(version: 2)
        XCTAssertEqual(reply, .refuse(.version(host: ProtocolVersion.network)))
    }

    func testAVersion3HelloIsRefusedWithVersion4() async throws {
        let p = try await pairedPeer("Phone")
        let reply = await p.hello(version: 3)
        XCTAssertEqual(reply, .refuse(.version(host: 4)))
    }

    func testRestartKeepsPairing() async throws {
        let first = try await pairedPeer("Phone")
        first.close()
        await service.stop()
        service = try makeService()
        port = try await service.start()
        let again = peer("Phone", like: first)
        try await again.open(port: port)
        XCTAssertTrue(again.sessionKnown)
    }

    func testPowerHold() async throws {
        _ = try await livePeer("Phone")
        let held = await waitUntil { self.power.calls.contains(true) }
        XCTAssertTrue(held, "\(power.calls)")
    }

    func testHelloAloneChangesNothing() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.setSilent(true)
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        let powerBefore = power.calls

        let replay = peer("Phone", like: a)
        try replay.connect(port: port)
        guard case .welcome? = await replay.hello() else { return XCTFail("no welcome") }
        await sleep(0.5)  // a negative: give the service a real chance to (wrongly) act
        XCTAssertEqual(power.calls, powerBefore)
        XCTAssertFalse(game.received.contains(.pause(false)))

        let b = try await pairedPeer("Tablet")
        try await b.open(port: port)
        XCTAssertTrue(b.sessionKnown, "second device admitted normally")
    }

    // MARK: clock

    /// A clock the test moves.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()  // guards t
        private var t = Date(timeIntervalSinceReferenceDate: 1_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    /// `silenceTimeout` is 3 s here. While the injected clock stands still, a silent client stays attached however much wall
    /// time passes; 3 s on the injected clock detaches it (and the session-end line counts on that clock too).
    func testTimersUseTheInjectedClock() async throws {
        let manual = ManualClock()
        await service.stop()
        service = try makeService(clock: { manual.now })
        port = try await service.start()
        let ends = StatusEnds(service.sessionEnds)
        let p = try await livePeer("Phone")
        p.setSilent(true)
        await sleep(3.6)  // more than the silence limit on the wall clock
        XCTAssertFalse(p.isClosed, "detached by the wall clock while the injected clock had not moved")
        manual.advance(3.2)
        let closed = await p.waitClosed(timeout: 3)
        XCTAssertTrue(closed, "the injected clock moved 3.2 s and the silent client is still attached")
        let ended = await ends.wait { !ends.all.isEmpty }
        XCTAssertTrue(ended)
        let seconds = ends.all.first?.seconds ?? 0
        XCTAssertEqual(seconds, 3.2, accuracy: 0.05, "the session length is not on the injected clock")
    }

    // MARK: unadmitted connections

    /// The shared service again, with a shorter unadmitted timeout.
    private func restart(unadmittedTimeout: TimeInterval) async throws {
        await service.stop()
        service = try makeService(unadmittedTimeout: unadmittedTimeout)
        port = try await service.start()
    }

    func testSilentConnectionClosedAfterTimeout() async throws {
        try await restart(unadmittedTimeout: 0.5)
        let p = peer("Stranger")
        try p.connect(port: port)
        let closed = await p.waitClosed(timeout: 3)
        XCTAssertTrue(closed, "a connection that never spoke is still open")
    }

    func testStalledAfterWelcomeClosedAfterTimeout() async throws {
        try await restart(unadmittedTimeout: 1)
        let p = try await pairedPeer("Phone")
        guard case .welcome? = await p.hello() else { return XCTFail("no welcome") }
        let closed = await p.waitClosed(timeout: 4)
        XCTAssertTrue(closed, "a connection that stopped after welcome is still open")
    }

    /// A wrong code, a pause past the timeout, then the right code: the same connection still opens.
    func testPairingAfterRetryCanOpen() async throws {
        try await restart(unadmittedTimeout: 1)
        let code = try await service.beginPairing()
        let wrong = String(code.map { $0 == "0" ? "1" : "0" })
        let p = peer("Phone")
        try p.connect(port: port)
        let first = try await p.pair(code: wrong)
        guard case .wrongCode = first else { return XCTFail("first try: \(first)") }
        await sleep(1.3)
        let second = try await p.pair(code: code)
        guard case .ok = second else { return XCTFail("pairing: \(second)") }
        await sleep(0.3)  // the app may take a moment before open(); the link has a full window
        try await p.open(port: port)
        XCTAssertTrue(p.sessionKnown)
    }

    func testUnadmittedConnectionsCapped() async throws {
        let a = try await livePeer("Phone")
        try await launchAndStream(a)
        var idle: [ScriptedPeer] = []
        for i in 0..<20 {
            let p = peer("Idle \(i)")
            try p.connect(port: port)
            idle.append(p)
        }
        let capped = await waitUntil(timeout: 3) { idle.filter { !$0.isClosed }.count <= 16 }
        XCTAssertTrue(capped, "open idle connections: \(idle.filter { !$0.isClosed }.count)")
        let n = a.received.count
        let more = await a.wait { a.received.count >= n + 10 }
        XCTAssertTrue(more, "the live session stopped receiving")
    }

    func testConnectionsOpenedAroundStopClosed() async throws {
        var late: [ScriptedPeer] = []
        for i in 0..<12 {
            let p = peer("Late \(i)")
            try p.connect(port: port)
            late.append(p)
        }
        await service.stop()
        let closed = await waitUntil(timeout: 3) { late.allSatisfy(\.isClosed) }
        XCTAssertTrue(closed, "open after stop: \(late.filter { !$0.isClosed }.count)")
    }

    // MARK: streaming

    func testLaunchStreams() async throws {
        let p = try await livePeer("Phone")
        let start = Date()
        p.send(.launch(titleID: fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running)
        let enough = await p.wait(timeout: 3 - Date().timeIntervalSince(start)) {
            p.received.count >= 60 && p.audio.filter { $0.count == 960 }.count >= 100
        }
        XCTAssertTrue(enough, "frames \(p.received.count), audio \(p.audio.count)")
        XCTAssertEqual(p.received.first?.frame.key, true)
        XCTAssertTrue(p.audio.allSatisfy { $0.count == 960 })
        XCTAssertLessThanOrEqual(p.largestDatagram, Wire.maxDatagram)
    }

    func testInputReachesGame() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p)
        p.sendInput(buttons: 1)
        let got = await waitGame { $0.contains(.pad(player: 0, buttons: 1, lx: 0, ly: 0, rx: 0, ry: 0)) }
        XCTAssertTrue(got)
    }

    func testStaleInputIgnored() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p)
        p.sendInput(buttons: 1, seq: 5)
        p.sendInput(buttons: 2, seq: 4)
        let got = await waitGame { self.pads($0).contains(1) }
        XCTAssertTrue(got)
        await sleep(0.3)  // a negative: the stale state must not follow
        // Zero pads are the neutral rule's, not input.
        XCTAssertEqual(pads(tapLog).filter { $0 != 0 }, [1])
    }

    func testKeyRequest() async throws {
        let p = try await livePeer("Phone")
        p.setAutoKeyRequest(false)
        let game = try await launchAndStream(p, frames: 10)
        let before = p.received.count
        p.sendDatagram(.keyRequest(lastGoodFrame: p.received.last?.frame.frame ?? 0))
        let keyed = await p.wait(timeout: 1) { p.received.dropFirst(before).contains { $0.frame.key } }
        XCTAssertTrue(keyed)

        await sleep(0.2)
        let k0 = count(.keyframe, in: game.received)
        for _ in 0..<10 {
            p.sendDatagram(.keyRequest(lastGoodFrame: p.received.last?.frame.frame ?? 0))
            await sleep(0.005)
        }
        await sleep(0.3)  // a negative: extra keyframes would have arrived by now
        let burst = count(.keyframe, in: game.received) - k0
        XCTAssertTrue((1...2).contains(burst), "keyframes \(burst)")
    }

    // MARK: long-term references -> .claude/host.md § ltr

    private func ltrAcks(_ log: [TapMessage]) -> [[Int32]] {
        log.compactMap { if case let .ltrAck(t) = $0 { return t }; return nil }
    }

    /// The newest frame the peer received that the game sent with a token.
    private func newestWithToken(_ p: ScriptedPeer, _ game: FakeGame) async -> (frame: UInt32, token: Int32)? {
        for _ in 0..<200 {
            let sent = game.sentFrames
            if let f = p.received.map(\.frame.frame).reversed().first(where: { (sent[$0]?.token ?? -1) >= 0 }) {
                return (f, sent[f]!.token)
            }
            await sleep(0.01)
        }
        return nil
    }

    /// `ack(frame)` of a frame with a token: the game gets `ltrAck([token])`, the token unchanged; an older or the same
    /// frame again gives nothing.
    func testAnAckSendsTheFramesTokenToTheGame() async throws {
        let p = try await livePeer("Phone")
        p.setAutoKeyRequest(false)
        let game = try await launchAndStream(p, frames: 10)
        let ackedFound = await newestWithToken(p, game)
        let acked = try XCTUnwrap(ackedFound, "no frame with a token")
        p.sendDatagram(.ack(frame: acked.frame))
        let got = await waitGame(timeout: 1) { self.ltrAcks($0) == [[acked.token]] }
        XCTAssertTrue(got, "\(ltrAcks(tapLog)) for token \(acked.token)")
        XCTAssertEqual(acked.token >> 24, 1, "the first session's epoch")
        p.sendDatagram(.ack(frame: acked.frame))
        if acked.frame > 0 { p.sendDatagram(.ack(frame: acked.frame - 1)) }
        await sleep(0.2)  // a negative: nothing more
        XCTAssertEqual(ltrAcks(tapLog).count, 1)
    }

    /// After an acknowledgement, `repair` becomes the tap's `refresh`; the game answers with a repair frame (not a key
    /// frame) after the frame already in flight, and every fragment of that frame, and only of it, carries the mark.
    func testARepairRequestIsARefreshAndTheRepairFrameIsMarked() async throws {
        let p = try await livePeer("Phone")
        p.setAutoKeyRequest(false)
        let game = try await launchAndStream(p, frames: 10)
        let ackedFound = await newestWithToken(p, game)
        let acked = try XCTUnwrap(ackedFound, "no frame with a token")
        p.sendDatagram(.ack(frame: acked.frame))
        _ = await waitGame(timeout: 1) { !self.ltrAcks($0).isEmpty }
        await sleep(0.05)
        let mark = game.framesSent
        p.sendDatagram(.repair(lastGoodFrame: acked.frame))
        let refreshed = await waitGame(timeout: 1) { $0.contains(.refresh) }
        XCTAssertTrue(refreshed)
        XCTAssertFalse(tapLog.contains(.keyframe), "a repair is not a key request")
        let repaired = await p.wait(timeout: 1) { p.fragments.contains { $0.repair } }
        XCTAssertTrue(repaired, "no repair frame")
        let sent = game.sentFrames
        let r = try XCTUnwrap(p.fragments.first { $0.repair }?.frame)
        XCTAssertEqual(sent[r]?.mark, .repair)
        XCTAssertTrue(p.fragments.filter { $0.frame == r }.allSatisfy { $0.repair && !$0.key })
        XCTAssertGreaterThan(Int(r), mark, "the frame in flight is not the repair frame")
        XCTAssertFalse(p.fragments.contains { $0.frame == r - 1 && $0.repair }, "the frame before it is not marked")
        XCTAssertFalse((UInt32(mark)...r).contains { sent[$0]?.mark == .key }, "a key frame came instead")
        XCTAssertEqual(game.repairsAnsweredWithKey, 0)
    }

    /// A `repair` asked again 35 ms after the first repair frame went out (it may still be on its way to the device): the
    /// Host passes both on (no duplicate swallowed) and the game answers each with its own repair frame. (A refresh that
    /// arrives while the previous repair frame is still to be encoded is served by that frame, as in the tap.)
    func testARepairAskedAgainAfter35msGetsItsOwnRepairFrame() async throws {
        let p = try await livePeer("Phone")
        p.setAutoKeyRequest(false)
        let game = try await launchAndStream(p, frames: 10)
        let ackedFound = await newestWithToken(p, game)
        let acked = try XCTUnwrap(ackedFound, "no frame with a token")
        p.sendDatagram(.ack(frame: acked.frame))
        _ = await waitGame(timeout: 1) { !self.ltrAcks($0).isEmpty }
        await sleep(0.05)
        let mark = game.framesSent
        p.sendDatagram(.repair(lastGoodFrame: acked.frame))
        let first = await p.wait(timeout: 1) { p.fragments.contains { $0.repair && Int($0.frame) >= mark } }
        XCTAssertTrue(first, "no first repair frame")
        await sleep(0.035)
        p.sendDatagram(.repair(lastGoodFrame: acked.frame))
        let both = await waitGame(timeout: 1) { $0.filter { $0 == .refresh }.count == 2 }
        XCTAssertTrue(both, "refreshes passed on: \(tapLog.filter { $0 == .refresh }.count)")
        let repaired = await p.wait(timeout: 1) { Set(p.fragments.filter { $0.repair && Int($0.frame) >= mark }.map(\.frame)).count >= 2 }
        let frames = game.sentFrames.filter { $0.key >= UInt32(mark) && $0.value.mark != .none }.sorted { $0.key < $1.key }
        XCTAssertTrue(repaired, "repair frames: \(frames.map { "\($0.key):\($0.value.mark)" })")
        XCTAssertEqual(frames.filter { $0.value.mark == .repair }.count, 2, "\(frames.map { "\($0.key):\($0.value.mark)" })")
        XCTAssertEqual(game.repairsAnsweredWithKey, 0)
    }

    /// Nothing acknowledged since the last key frame: the game answers the refresh with a key frame.
    func testARepairWithNothingAcknowledgedIsAnsweredWithAKeyFrame() async throws {
        let p = try await livePeer("Phone")
        p.setAutoKeyRequest(false)
        let game = try await launchAndStream(p, frames: 10)
        let mark = game.framesSent
        p.sendDatagram(.repair(lastGoodFrame: 0))
        let keyed = await p.wait(timeout: 1) { p.fragments.contains { $0.key && Int($0.frame) >= mark } }
        XCTAssertTrue(keyed)
        XCTAssertFalse(p.fragments.contains { $0.repair })
        XCTAssertTrue(tapLog.contains(.refresh))
    }

    /// An admitted session whose first `rate` is still on its way when the game's tap `hello` arrives: the game's first
    /// `config` carries the client's start rate (its controller's, half the 20 Mbit/s ceiling), never the ceiling.
    func testTheGamesFirstConfigIsTheStartRateWhenItsHelloComesBeforeTheFirstRate() async throws {
        let a = try await pairedPeer("Phone")
        let reply = await a.hello(bitrate: 20_000_000, startBps: 10_000_000)
        guard case .welcome? = reply else { return XCTFail("no welcome: \(String(describing: reply))") }
        try a.ready()  // admitted; no `rate` is sent before the game's first config
        a.startPings()
        a.send(.launch(titleID: fakeID))
        let configured = await waitGame { $0.contains { if case .config = $0 { true } else { false } } }
        XCTAssertTrue(configured, "the game got no config")
        let first = tapLog.first { if case .config = $0 { true } else { false } }
        XCTAssertEqual(first, .config(maxWidth: 1920, maxHeight: 1080, maxFps: 60, bitrate: 10_000_000), "the first config of the game")
    }

    /// The hello's start rate is kept as the session's rate, clamped as a `rate` is: never over the hello's wish, never
    /// under 1 Mbit/s; absent = none (the wish until the first `rate`, as before).
    func testTheHellosStartRateIsClampedAsARateIs() async throws {
        for (start, want) in [(UInt32(50_000_000), UInt32(20_000_000)), (100_000, HostDefaults.minBitrate), (12_000_000, 12_000_000), (nil, nil)] {
            let a = try await pairedPeer("Phone \(String(describing: start))")
            guard case .welcome? = await a.hello(bitrate: 20_000_000, startBps: start) else { return XCTFail("no welcome") }
            let kept = await service.keptRate(of: a.name)
            XCTAssertEqual(kept, want, "start \(String(describing: start))")
            a.close()
        }
    }

    /// A rate waiting out its 250 ms goes to the game before the refresh, as before a key frame.
    func testAPendingRateGoesToTheGameBeforeARefresh() async throws {
        let (p, game) = try await rateSession()
        p.setAutoKeyRequest(false)
        p.sendDatagram(.rate(bitsPerSecond: 30_000_000))
        _ = await waitGame(timeout: 1) { self.rates($0).last == 30_000_000 }
        await sleep(0.05)
        let mark = game.received.count
        p.sendDatagram(.rate(bitsPerSecond: 9_000_000))
        await sleep(0.01)
        p.sendDatagram(.repair(lastGoodFrame: 0))
        let refreshed = await waitGame(timeout: 1) { $0.dropFirst(mark).contains(.refresh) }
        XCTAssertTrue(refreshed)
        let tail = Array(game.received.dropFirst(mark))
        let cfg = tail.firstIndex(of: .config(maxWidth: 1920, maxHeight: 1080, maxFps: 60, bitrate: 9_000_000))
        let refresh = tail.firstIndex(of: .refresh)
        XCTAssertNotNil(cfg, "the rate was not passed with the repair request: \(rates(tail))")
        if let cfg, let refresh { XCTAssertLessThan(cfg, refresh) }
    }

    /// `ack` and `repair` sealed for a welcomed session that is not the live one change nothing.
    func testAnAckOrRepairFromASessionThatIsNotLiveIsIgnored() async throws {
        let a = try await livePeer("Phone")
        a.setAutoKeyRequest(false)
        let game = try await launchAndStream(a, frames: 10)
        let ackedFound = await newestWithToken(a, game)
        let acked = try XCTUnwrap(ackedFound, "no frame with a token")
        let again = peer("Phone", like: a)
        try again.connect(port: port)
        let reply = await again.hello()
        guard case .welcome? = reply else { return XCTFail("no welcome: \(String(describing: reply))") }
        try again.addSocket()
        again.sendDatagram(.ack(frame: acked.frame))
        again.sendDatagram(.repair(lastGoodFrame: 0))
        await sleep(0.3)  // a negative
        XCTAssertEqual(ltrAcks(tapLog), [], "\(tapLog.suffix(8))")
        XCTAssertFalse(tapLog.contains(.refresh), "\(tapLog.suffix(8))")
        // The control: the same from the live session reaches the game.
        a.sendDatagram(.ack(frame: acked.frame))
        a.sendDatagram(.repair(lastGoodFrame: acked.frame))
        let reached = await waitGame(timeout: 1) { self.ltrAcks($0) == [[acked.token]] && $0.contains(.refresh) }
        XCTAssertTrue(reached, "the live session's ack and repair did not reach the game: \(tapLog.suffix(8))")
    }

    /// The game's `prepare` messages are kept (the newest) and logged once per phase start and end.
    func testThePreparationIsKeptAndLoggedOncePerPhaseStartAndEnd() async throws {
        await service.stop()
        launcher = FakeLauncher(preparePhases: [100, 0])
        service = try makeService()
        port = try await service.start()
        let notes = service.notes
        let lines = LineBox()
        let reader = Task { for await l in notes { lines.add(l) } }
        defer { reader.cancel() }
        let p = try await livePeer("Phone")
        try await launchAndStream(p, frames: 5)
        let prepare = await service.gamePrepare
        XCTAssertEqual(prepare, GamePrepare(phase: 2, done: 0, total: 0))
        let got = lines.all.filter { $0.hasPrefix("game prepare") }
        let expected = ["game prepare: phase 1 started (0/100)", "game prepare: phase 1 done (100/100) in ",
                        "game prepare: phase 2 started (0/0)", "game prepare: phase 2 done (0/0) in "]
        XCTAssertEqual(got.count, expected.count, "\(got)")
        for (line, start) in zip(got, expected) { XCTAssertTrue(line.hasPrefix(start), "\(got)") }
    }

    // MARK: preparing

    private func restart(_ l: FakeLauncher) async throws {
        await service.stop()
        launcher = l
        service = try makeService()
        port = try await service.start()
    }

    private func progress(_ p: ScriptedPeer) -> [Preparing] {
        p.messages.compactMap(\.gameState?.preparing).filter { $0.total > 0 }
    }

    /// The game's `prepare` reaches the device as `preparing` with `done` rising; the pictures end it.
    func testPreparingReachesTheDeviceAndEndsWithThePictures() async throws {
        try await restart(FakeLauncher(stall: 1.5))
        let p = try await livePeer("Phone")
        p.send(.launch(titleID: fakeID))
        let first = await p.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
        XCTAssertEqual(first?.gameState?.preparing?.phase, 1)
        let later = await p.next { ($0.gameState?.preparing?.done ?? 0) >= 600 }
        XCTAssertNotNil(later, "\(progress(p))")
        let streaming = await p.wait { p.received.count >= 3 }
        XCTAssertTrue(streaming)
        let last = try XCTUnwrap(p.messages.compactMap(\.gameState).last)
        XCTAssertNil(last.preparing, "the pictures end it: \(last)")
        XCTAssertEqual(last.run, .running)
        let dones = progress(p).map(\.done)
        XCTAssertEqual(dones, dones.sorted(), "done never goes backward: \(dones)")
    }

    /// A game that sends four `prepare` in under a second: at most two progress states a second reach the device.
    func testProgressGoesOutAtMostTwiceASecond() async throws {
        let steps = [100, 300, 600, 1000].map { FakeGame.PrepareStep(phase: 1, done: UInt32($0), total: 1000) }
        try await restart(FakeLauncher(prepareSteps: steps, stall: 0.8))
        let p = try await livePeer("Phone")
        p.send(.launch(titleID: fakeID))
        var series: [(Date, Int)] = []
        let end = Date().addingTimeInterval(2.5)
        while Date() < end {
            series.append((Date(), progress(p).count))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let total = series.last?.1 ?? 0
        XCTAssertGreaterThanOrEqual(total, 1, "no progress reached the device")
        for (t, n) in series {
            let before = series.last { $0.0 <= t.addingTimeInterval(-1) }?.1 ?? 0
            XCTAssertLessThanOrEqual(n - before, 2, "more than two progress states in one second")
        }
        XCTAssertLessThan(total, 4, "the four prepare messages were not thinned: \(progress(p))")
    }

    /// A session that ends while the game prepares does not pause it; the pause goes out once, when the pictures begin.
    /// A device that comes later is told the game is paused, with no `preparing`.
    func testLeavingWhilePreparingDoesNotPauseUntilThePreparationEnds() async throws {
        try await restart(FakeLauncher(stall: 3))
        let a = try await livePeer("Phone")
        a.send(.launch(titleID: fakeID))
        let preparing = await a.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
        XCTAssertNotNil(preparing)
        await sleep(1)
        a.close()
        await sleep(1.5)  // a negative: the stall (3 s) is still running
        let game = try XCTUnwrap(launcher.game)
        XCTAssertEqual(game.framesSent, 0, "the preparation ended too early for this test")
        XCTAssertFalse(tapLog.contains(.pause(true)), "paused during the preparation: \(tapLog.suffix(6))")
        let paused = await waitGame(timeout: 5) { $0.contains(.pause(true)) }
        XCTAssertTrue(paused, "no pause after the preparation: \(tapLog.suffix(6))")
        XCTAssertGreaterThan(game.framesSent, 0)
        await sleep(0.3)
        XCTAssertEqual(count(.pause(true), in: tapLog), 1)
        let b = try await livePeer("Tablet")
        let state = await b.next { $0.gameState != nil }
        XCTAssertEqual(state?.gameState?.run, .paused)
        XCTAssertNil(state?.gameState?.preparing, "never reported for a paused game")
    }

    /// A device that connects meanwhile is told `preparing` first.
    func testADeviceThatConnectsMeanwhileIsTold() async throws {
        try await restart(FakeLauncher(stall: 3))
        let a = try await livePeer("Phone")
        a.send(.launch(titleID: fakeID))
        let started = await a.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
        XCTAssertNotNil(started)
        a.close()
        await sleep(0.5)
        let b = try await livePeer("Tablet")
        let first = await b.next { $0.gameState != nil }
        XCTAssertNotNil(first?.gameState?.preparing, "\(String(describing: first))")
    }

    /// Back within the preparation: the same device resumes a game that was never paused.
    func testTheSameDeviceReturningDuringPreparationSendsNoPauseOrResume() async throws {
        try await restart(FakeLauncher(stall: 2))
        let a = try await livePeer("Phone")
        a.send(.launch(titleID: fakeID))
        _ = await a.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
        a.close()
        await sleep(0.3)
        let again = peer("Phone", like: a)
        try await again.open(port: port)
        let streaming = await again.wait(timeout: 6) { again.received.count >= 3 }
        XCTAssertTrue(streaming)
        XCTAssertFalse(tapLog.contains(.pause(true)), "\(tapLog.suffix(6))")
        XCTAssertFalse(tapLog.contains(.pause(false)), "\(tapLog.suffix(6))")
    }

    // MARK: library sessions (`hello.resume == false`)

    /// The device that paused the game opens a library session: told `paused`, nothing resumes, no picture or sound; its
    /// `resume` then plays as before.
    func testALibrarySessionToAPausedGameIsToldPausedAndPlaysOnlyOnResume() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.close()
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        let lib = peer("Phone", like: a)
        try await lib.open(port: port, resume: false)
        let state = await lib.next { $0.gameState != nil }
        XCTAssertEqual(state?.gameState?.run, .paused)
        await sleep(0.5)  // a negative: nothing resumes and nothing is relayed
        XCTAssertFalse(game.received.contains(.pause(false)), "\(game.received.suffix(6))")
        XCTAssertEqual(lib.received.count, 0)
        XCTAssertEqual(lib.audio.count, 0)
        lib.send(.resume)
        let resumed = await waitGame { $0.contains(.pause(false)) }
        XCTAssertTrue(resumed)
        let frames = await lib.wait { lib.received.count >= 3 && lib.audio.count >= 1 }
        XCTAssertTrue(frames, "frames \(lib.received.count), audio \(lib.audio.count)")
    }

    /// Device A paused its game; device B's library session never reconfigures it (not at admission, not for its `rate`,
    /// not for a lowered ceiling); B's `resume` then sends one `config` with B's size, frame rate and rate.
    func testALibrarySessionNeverReconfiguresTheGame() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.close()
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        let mark = game.received.count
        let b = try await pairedPeer("Tablet")
        try await b.open(port: port, maxWidth: 1280, maxHeight: 720, maxFps: 30, bitrate: 8_000_000, resume: false, startBps: 5_000_000)
        let state = await b.next { $0.gameState != nil }
        XCTAssertEqual(state?.gameState?.run, .paused)
        b.sendDatagram(.rate(bitsPerSecond: 6_000_000))
        await sleep(0.4)  // past the 250 ms between configs
        b.send(.liveSettings(LiveSettings(ceilingBps: 4_000_000)))
        await sleep(0.4)  // a negative: nothing reaches the game
        XCTAssertEqual(rates(Array(game.received.dropFirst(mark))), [], "\(game.received.dropFirst(mark))")
        b.send(.resume)
        let resumed = await waitGame { $0.dropFirst(mark).contains(.pause(false)) }
        XCTAssertTrue(resumed)
        await sleep(0.3)
        let configs = game.received.dropFirst(mark).filter { if case .config = $0 { true } else { false } }
        XCTAssertEqual(configs, [.config(maxWidth: 1280, maxHeight: 720, maxFps: 30, bitrate: 4_000_000)])
    }

    /// A device coming back with another size: the game is configured BEFORE it is resumed (as `play()` does), so its first
    /// pictures are at the new size and rate, never the old one.
    func testAnAdmissionConfiguresTheGameBeforeItResumesIt() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.close()
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        let mark = game.received.count
        let again = peer("Phone", like: a)
        try await again.open(port: port, maxWidth: 1280, maxHeight: 720)
        let resumed = await waitGame { $0.dropFirst(mark).contains(.pause(false)) }
        XCTAssertTrue(resumed)
        let after = Array(game.received.dropFirst(mark))
        let config = after.firstIndex { if case .config = $0 { true } else { false } }
        let resume = after.firstIndex(of: .pause(false))
        XCTAssertNotNil(config, "\(after)")
        XCTAssertLessThan(config ?? Int.max, resume ?? 0, "the config comes before the resume: \(after)")
    }

    /// A picture's size is judged against the size limit of the session that PLAYS: a library session of a device with a
    /// smaller limit does not turn the game's size into "a lower bound" (the game was configured for the player's).
    func testThePictureSizeIsJudgedAgainstThePlayersLimitNotALibraryDevices() async throws {
        try await restart(FakeLauncher(stall: 2, width: 1920, height: 1080))
        let player = try await pairedPeer("Player")
        try await player.open(port: port, maxWidth: 2560, maxHeight: 1440)
        player.send(.launch(titleID: fakeID))
        _ = await player.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
        player.close()
        await sleep(0.3)
        let lib = try await pairedPeer("Tablet")
        try await lib.open(port: port, maxWidth: 1280, maxHeight: 720, resume: false)
        let told = await lib.next(timeout: 6) { $0.gameState?.render != nil }
        XCTAssertEqual(told?.gameState?.render, RenderSize(width: 1920, height: 1080, exact: true),
                       "under the player's 2560 x 1440, not the library device's 1280 x 720")
    }

    /// A launches a slow-preparing game and leaves; a session that does not play (a library one of A or of another device,
    /// or another device's keyless one) is live at the first picture: the owed pause still goes out once and the session is
    /// told `paused`; no picture reaches it.
    func testALibrarySessionAtTheFirstPictureDoesNotStopTheOwedPause() async throws {
        // The third case is a keyless (resuming) hello of another device: the game is not its to resume, so it does not play.
        for (sameDevice, resumeKey) in [(true, false), (false, false), (false, nil)] as [(Bool, Bool?)] {
            try await restart(FakeLauncher(stall: 2))
            let a = try await livePeer("Phone")
            a.send(.launch(titleID: fakeID))
            _ = await a.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
            a.close()
            await sleep(0.3)
            let lib: ScriptedPeer
            if sameDevice {
                lib = peer("Phone", like: a)
            } else {
                lib = try await pairedPeer("Tablet")
            }
            try await lib.open(port: port, resume: resumeKey)
            let first = await lib.next { $0.gameState != nil }
            XCTAssertEqual(first?.gameState?.run, .running, "same device \(sameDevice)")
            XCTAssertNotNil(first?.gameState?.preparing, "same device \(sameDevice)")
            let pausedNow = await waitGame(timeout: 6) { $0.contains(.pause(true)) }
            XCTAssertTrue(pausedNow, "same device \(sameDevice): \(tapLog.suffix(6))")
            let told = await lib.next { $0.gameState?.run == .paused }
            XCTAssertNotNil(told, "same device \(sameDevice)")
            await sleep(0.3)
            XCTAssertEqual(count(.pause(true), in: tapLog), 1, "same device \(sameDevice)")
            XCTAssertFalse(tapLog.contains(.pause(false)), "same device \(sameDevice)")
            XCTAssertEqual(lib.received.count, 0, "same device \(sameDevice)")
            lib.close()
            a.close()
        }
    }

    /// A library session that plays (`resume`, or `launch` of the preparing game) during the preparation clears the owed
    /// pause: the game is never paused under it and its pictures arrive.
    func testALibrarySessionThatPlaysDuringThePreparationIsNeverPausedUnder() async throws {
        for (sameDevice, ask) in [(true, ControlMessage.resume), (true, .launch(titleID: fakeID)),
                                  (false, .resume), (false, .launch(titleID: fakeID))] {
            try await restart(FakeLauncher(stall: 2))
            let a = try await livePeer("Phone")
            a.send(.launch(titleID: fakeID))
            _ = await a.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
            a.close()
            await sleep(0.3)
            let lib = sameDevice ? peer("Phone", like: a) : try await pairedPeer("Tablet")
            try await lib.open(port: port, resume: false)
            _ = await lib.next { $0.gameState != nil }
            lib.send(ask)
            let streaming = await lib.wait(timeout: 6) { lib.received.count >= 3 }
            XCTAssertTrue(streaming, "same device \(sameDevice), \(ask): frames \(lib.received.count)")
            XCTAssertFalse(tapLog.contains(.pause(true)), "same device \(sameDevice), \(ask): \(tapLog.suffix(6))")
            XCTAssertFalse(tapLog.contains(.pause(false)), "same device \(sameDevice), \(ask): \(tapLog.suffix(6))")
            XCTAssertEqual(lib.messages.compactMap(\.gameState).last?.run, .running, "same device \(sameDevice), \(ask)")
            lib.close()
        }
    }

    /// The game dies while its pause is owed: nothing stale is left, the next game of the same Mac is never paused for it.
    func testTheGameDyingWhileThePauseIsOwedLeavesNoStaleFlag() async throws {
        try await restart(FakeLauncher(stall: 3))
        let a = try await livePeer("Phone")
        a.send(.launch(titleID: fakeID))
        _ = await a.next { ($0.gameState?.preparing?.total ?? 0) > 0 }
        a.close()
        await sleep(0.3)
        launcher.game?.stop()
        let idle = await waitGame { _ in self.launcher.game?.isFinished == true }
        XCTAssertTrue(idle)
        await sleep(0.5)
        let lib = peer("Phone", like: a)
        try await lib.open(port: port, resume: false)
        let state = await lib.next { $0.gameState != nil }
        XCTAssertEqual(state?.gameState?.run, .idle, "the dead game is gone")
        lib.send(.launch(titleID: fakeID))
        let streaming = await lib.wait(timeout: 8) { lib.received.count >= 3 }
        XCTAssertTrue(streaming, "frames \(lib.received.count)")
        XCTAssertFalse(tapLog.contains(.pause(true)), "the new game was paused for the old one: \(tapLog.suffix(6))")
    }

    /// A library session does not hold the Mac: another paired device is welcomed and lists the games; the library
    /// session ends as `replaced`, told by a sealed `bye` naming the device the Mac is now in use on.
    func testALibrarySessionGivesWayToAnotherDevice() async throws {
        let ends = StatusEnds(service.sessionEnds)
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, resume: false)
        _ = await a.next { $0.gameState != nil }
        let b = try await pairedPeer("Tablet")
        try await b.open(port: port)
        b.send(.listRequest)
        let list = await b.next { if case .list = $0 { true } else { false } }
        XCTAssertNotNil(list, "the newcomer was not served")
        let bye = await a.next { if case .bye = $0 { true } else { false } }
        XCTAssertEqual(bye, .bye(takenBy: "Tablet"))
        let closed = await a.waitClosed()
        XCTAssertTrue(closed)
        let ended = await ends.wait { ends.all.contains { $0.device == a.tag } }
        XCTAssertTrue(ended)
        XCTAssertEqual(ends.all.first { $0.device == a.tag }?.cause, .replaced)
    }

    /// A playing session keeps the Mac: another device is refused busy, word for word as before.
    func testAPlayingSessionStillRefusesAnotherDevice() async throws {
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, resume: false)
        try await launchAndStream(a)
        let b = try await pairedPeer("Tablet")
        let reply = await b.hello()
        XCTAssertEqual(reply, .refuse(.busy(device: "Phone")))
        XCTAssertFalse(a.messages.contains { if case .bye = $0 { true } else { false } })
    }

    /// Device A plays, quits and sits on the library: that is a library session, so device B is welcomed and A is told.
    func testAQuitGameFreesTheMacForAnotherDevice() async throws {
        let ends = StatusEnds(service.sessionEnds)
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, resume: false)
        try await launchAndStream(a)
        a.send(.quitGame)
        let idle = await a.next { $0.gameState?.run == .idle }
        XCTAssertNotNil(idle, "the game did not end")
        let b = try await pairedPeer("Tablet")
        try await b.open(port: port)
        b.send(.listRequest)
        let list = await b.next { if case .list = $0 { true } else { false } }
        XCTAssertNotNil(list, "the newcomer was refused (busy) from an idle library")
        let bye = await a.next { if case .bye = $0 { true } else { false } }
        XCTAssertEqual(bye, .bye(takenBy: "Tablet"))
        let ended = await ends.wait { ends.all.contains { $0.device == a.tag } }
        XCTAssertTrue(ended)
        XCTAssertEqual(ends.all.first { $0.device == a.tag }?.cause, .replaced)
    }

    /// Device A's game dies while A is away; A reconnects resuming into an idle Mac and is no player, so device B is
    /// welcomed and A is ended as replaced.
    func testAResumingSessionOnAnIdleMacDoesNotHoldIt() async throws {
        let ends = StatusEnds(service.sessionEnds)
        let a = try await livePeer("Phone")
        _ = try await launchAndStream(a)
        a.close()
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        launcher.game?.stop()
        let finished = await waitGame { _ in self.launcher.game?.isFinished == true }
        XCTAssertTrue(finished)
        let gone = await waitGame { _ in true }  // the tap log is read below; the Host's own view of the game decides
        XCTAssertTrue(gone)
        var listed = true
        for _ in 0..<400 where listed {
            listed = await service.games().first { $0.titleID == fakeID }?.state != .idle
            if listed { await sleep(0.01) }
        }
        XCTAssertFalse(listed, "the Host still holds the dead game")
        let again = peer("Phone", like: a)
        try await again.open(port: port)
        let idle = await again.next { $0.gameState?.run == .idle }
        XCTAssertNotNil(idle, "the dead game is gone")
        let b = try await pairedPeer("Tablet")
        try await b.open(port: port)
        b.send(.listRequest)
        let list = await b.next { if case .list = $0 { true } else { false } }
        XCTAssertNotNil(list, "the newcomer was refused (busy) by a session with no game")
        let bye = await again.next { if case .bye = $0 { true } else { false } }
        XCTAssertEqual(bye, .bye(takenBy: "Tablet"))
        let ended = await ends.wait { ends.all.filter { $0.device == a.tag }.count >= 2 }
        XCTAssertTrue(ended)
        XCTAssertEqual(ends.all.last { $0.device == a.tag }?.cause, .replaced)
    }

    /// A library session on an idle Mac sends `resume` (a stale tile): there is no game to play, so it stays a library session,
    /// is told the Mac is idle, and another device is welcomed while the first is ended as replaced.
    func testAResumeWithNoGameDoesNotMakeALibrarySessionPlay() async throws {
        let ends = StatusEnds(service.sessionEnds)
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, resume: false)
        _ = await a.next { $0.gameState != nil }
        a.send(.resume)
        let answer = await a.next { $0.gameState != nil }
        XCTAssertEqual(answer?.gameState?.run, .idle, "a resume with no game is answered with the idle state")
        let b = try await pairedPeer("Tablet")
        try await b.open(port: port)
        b.send(.listRequest)
        let list = await b.next { if case .list = $0 { true } else { false } }
        XCTAssertNotNil(list, "the newcomer was refused (busy) by a library session that asked to resume nothing")
        let bye = await a.next { if case .bye = $0 { true } else { false } }
        XCTAssertEqual(bye, .bye(takenBy: "Tablet"))
        let ended = await ends.wait { ends.all.contains { $0.device == a.tag } }
        XCTAssertTrue(ended)
        XCTAssertEqual(ends.all.first { $0.device == a.tag }?.cause, .replaced)
    }

    // MARK: render size

    private func renders(_ p: ScriptedPeer) -> [RenderSize] {
        var out: [RenderSize] = []
        for r in p.messages.compactMap(\.gameState).compactMap(\.render) where out.last != r { out.append(r) }
        return out
    }

    /// The game's own picture is smaller than the device's cap: it is told as exact.
    func testTheGameStateTellsWhatTheGameRenders() async throws {
        try await restart(FakeLauncher(width: 1920, height: 1080))
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, maxWidth: 2560, maxHeight: 1440)
        _ = try await launchAndStream(a)
        let got = await a.next { $0.gameState?.render != nil }
        XCTAssertEqual(got?.gameState?.render, RenderSize(width: 1920, height: 1080, exact: true))
    }

    /// The cap held the game (the picture is the cap): not exact, the game may render more.
    func testACapBelowTheGamesSizeIsNotExact() async throws {
        try await restart(FakeLauncher(width: 1920, height: 1080))
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, maxWidth: 1280, maxHeight: 720)
        _ = try await launchAndStream(a)
        let got = await a.next { $0.gameState?.render != nil }
        XCTAssertEqual(got?.gameState?.render, RenderSize(width: 1280, height: 720, exact: false))
    }

    /// The tap fits a picture into the cap by aspect: a game with a side held by the cap is a lower bound, whatever shape.
    func testAFittedPictureIsALowerBound() async throws {
        let cases: [(w: Int, h: Int, cw: UInt16, ch: UInt16, want: RenderSize)] = [
            (1920, 1200, 1920, 1080, RenderSize(width: 1728, height: 1080, exact: false)),  // 16:10 under 16:9
            (1600, 1200, 1920, 1080, RenderSize(width: 1440, height: 1080, exact: false)),  // 4:3 under 16:9
            (1920, 1080, 1920, 1080, RenderSize(width: 1920, height: 1080, exact: false)),  // exactly the cap
            (1280, 720, 1920, 1080, RenderSize(width: 1280, height: 720, exact: true)),     // under both sides
            (1080, 1920, 1920, 1080, RenderSize(width: 606, height: 1080, exact: false)),   // portrait
        ]
        for c in cases {
            try await restart(FakeLauncher(width: c.w, height: c.h))
            let a = try await pairedPeer("Phone")
            try await a.open(port: port, maxWidth: c.cw, maxHeight: c.ch)
            _ = try await launchAndStream(a)
            let got = await a.next { $0.gameState?.render != nil }
            XCTAssertEqual(got?.gameState?.render, c.want, "\(c.w)x\(c.h) under \(c.cw)x\(c.ch)")
            a.close()
        }
    }

    /// A size change (the device came back with another cap) is told once; a new game has none until its first frame.
    func testASizeChangeIsToldOnceAndANewGameStartsWithNone() async throws {
        try await restart(FakeLauncher(width: 1920, height: 1080))
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, maxWidth: 2560, maxHeight: 1440)
        _ = try await launchAndStream(a)
        a.close()
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        let again = peer("Phone", like: a)
        try await again.open(port: port, maxWidth: 1280, maxHeight: 720)
        let changed = await again.next { $0.gameState?.render?.width == 1280 }
        XCTAssertNotNil(changed)
        await sleep(0.4)
        // The stale size is what the game rendered until the first picture at the new cap; then the change, once.
        XCTAssertEqual(renders(again), [RenderSize(width: 1920, height: 1080, exact: true), RenderSize(width: 1280, height: 720, exact: false)])
        again.send(.quitGame)
        _ = await again.next { $0.gameState?.run == .idle }
        XCTAssertNil(again.messages.compactMap(\.gameState).last?.render, "a game that ended has no size")
        again.send(.launch(titleID: fakeID))
        let starting = await again.next { $0.gameState?.run == .starting }
        XCTAssertNotNil(starting)
        XCTAssertNil(starting?.gameState?.render, "the new game has made no picture yet")
        let first = await again.next { $0.gameState?.render != nil }
        XCTAssertNotNil(first)
    }

    /// The same device reconnecting over its own stale session is no take-over: its old link is not told another device
    /// has the Mac, and the new one plays.
    func testTheSameDevicesReconnectSendsNoTakenBy() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        let mark = game.received.count
        let again = peer("Phone", like: a)
        try await again.open(port: port)
        let streaming = await again.wait(timeout: 6) { again.received.count >= 3 }
        XCTAssertTrue(streaming, "frames \(again.received.count)")
        await sleep(0.3)
        // Over its own live link the device resumes at once: the game is configured before it is asked for a key frame.
        let after = Array(game.received.dropFirst(mark))
        let config = after.firstIndex { if case .config = $0 { true } else { false } }
        let key = after.firstIndex(of: .keyframe)
        XCTAssertNotNil(config, "\(after)")
        let k = try XCTUnwrap(key, "the reconnect asks for a key frame: \(after)")
        if let config { XCTAssertLessThan(config, k, "config before the key frame request: \(after)") }
        let taken = a.messages.contains { if case .bye(let by) = $0 { by != nil } else { false } }
        XCTAssertFalse(taken, "the same device was told another device took the Mac")
    }

    /// `keyRequest` and `repair` from a session that does not play reach no game.
    func testKeyAndRepairRequestsFromALibrarySessionAreIgnored() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.close()
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        let lib = peer("Phone", like: a)
        try await lib.open(port: port, resume: false)
        _ = await lib.next { $0.gameState != nil }
        await sleep(0.2)
        let keys = count(.keyframe, in: game.received), refreshes = count(.refresh, in: game.received)
        lib.sendDatagram(.keyRequest(lastGoodFrame: 0))
        await sleep(0.15)
        lib.sendDatagram(.repair(lastGoodFrame: 0))
        await sleep(0.4)  // a negative: nothing reaches the game
        XCTAssertEqual(count(.keyframe, in: game.received), keys)
        XCTAssertEqual(count(.refresh, in: game.received), refreshes)
    }

    /// Input from a session that does not play moves no pad of the game paused under it.
    func testInputFromALibrarySessionReachesNoGame() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.close()
        let paused = await waitGame { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)
        let lib = peer("Phone", like: a)
        try await lib.open(port: port, resume: false)
        _ = await lib.next { $0.gameState != nil }
        lib.sendInput(buttons: 4)
        await sleep(0.4)  // a negative: nothing reaches the game
        XCTAssertFalse(pads(game.received).contains(4), "a library session's input reached the game")
    }

    // MARK: resends

    /// The newest frame the peer put together, and its fragments as they first arrived.
    private func newestFrame(_ p: ScriptedPeer) throws -> (frame: UInt32, fragments: [VideoFragment]) {
        let frame = try XCTUnwrap(p.received.last?.frame.frame)
        var seen = Set<UInt16>()
        let fs = p.fragments.filter { $0.frame == frame && seen.insert($0.index).inserted }
        return (frame, fs)
    }

    private func copies(_ p: ScriptedPeer, after mark: Int, frame: UInt32) -> [VideoFragment] {
        Array(p.fragments.dropFirst(mark).filter { $0.frame == frame })
    }

    func testANackIsAnsweredWithExactlyTheAskedFragments() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p, frames: 10)
        let (frame, original) = try newestFrame(p)
        let mark = p.fragments.count
        p.sendDatagram(.nack(frame: frame, indices: [0]))
        let got = await p.wait(timeout: 1) { !self.copies(p, after: mark, frame: frame).isEmpty }
        XCTAssertTrue(got, "no resend of frame \(frame)")
        await sleep(0.1)  // a negative: nothing more of that frame
        let resent = copies(p, after: mark, frame: frame)
        XCTAssertEqual(resent, [original[0]], "opened by the peer (a fresh counter), equal to the original")

        let mark2 = p.fragments.count
        p.sendDatagram(.nack(frame: frame, indices: []))
        let all = await p.wait(timeout: 1) { self.copies(p, after: mark2, frame: frame).count >= original.count }
        XCTAssertTrue(all)
        await sleep(0.1)
        XCTAssertEqual(Set(copies(p, after: mark2, frame: frame).map(\.index)), Set(original.map(\.index)))
        XCTAssertEqual(copies(p, after: mark2, frame: frame).count, original.count)
    }

    func testTheSameFragmentIsResentAtMostOnceEvery4ms() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p, frames: 10)
        let (frame, _) = try newestFrame(p)
        let mark = p.fragments.count
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<10 { p.sendDatagram(.nack(frame: frame, indices: [0])) }
        let spanMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        _ = await p.wait(timeout: 1) { !self.copies(p, after: mark, frame: frame).isEmpty }
        await sleep(0.1)
        let n = copies(p, after: mark, frame: frame).count
        // The Host takes the ten from one ordered stream, so they cannot spread wider than they were sent by much.
        XCTAssertTrue((1...(2 + Int(spanMs / 4))).contains(n), "\(n) copies for 10 asks sent in \(spanMs) ms")
    }

    /// Review Focus 4: asks for what the Host never kept cost nothing and are counted.
    func testHostileNacksAreRefusedAndCounted() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p, frames: 10)
        let (frame, original) = try newestFrame(p)
        let mark = p.fragments.count
        p.sendDatagram(.nack(frame: frame, indices: [UInt16(original.count), 65_535]))
        p.sendDatagram(.nack(frame: frame &+ 1_000_000, indices: []))
        p.sendDatagram(.nack(frame: frame &- 1_000_000, indices: [0]))
        let counted = await waitService { $0.unknownFrame >= 2 && $0.badIndex >= 2 }
        let refused = await service.resendRefused
        XCTAssertTrue(counted, "\(refused)")
        XCTAssertEqual(copies(p, after: mark, frame: frame), [])
        XCTAssertFalse(p.isClosed)
    }

    /// Review Focus 5: a stopped game's frames are not resent (the next game numbers from 0 again).
    func testTheStoreIsClearedWhenTheGameStops() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p, frames: 10)
        let (frame, _) = try newestFrame(p)
        p.send(.quitGame)
        let idle = await p.next(timeout: 8) { $0.gameState?.run == .idle }
        XCTAssertNotNil(idle)
        let mark = p.fragments.count
        let before = await service.resendRefused.unknownFrame
        p.sendDatagram(.nack(frame: frame, indices: [0]))
        let counted = await waitService { $0.unknownFrame > before }
        XCTAssertTrue(counted)
        XCTAssertEqual(copies(p, after: mark, frame: frame), [])
    }

    /// Once a second the live session is told the Host's own counts; the frames counted are the ones it was sent.
    func testHostStatsArriveOnceASecond() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p, frames: 10)
        let got = await p.wait(timeout: 3) { p.hostStats.count >= 2 }
        XCTAssertTrue(got, "\(p.hostStats.count) hostStats")
        let h = try XCTUnwrap(p.hostStats.last)
        XCTAssertGreaterThan(h.framesFromGame, 0)
        XCTAssertGreaterThan(h.framesSent, 0)
        XCTAssertLessThanOrEqual(h.framesSent, h.framesFromGame)
        XCTAssertEqual(h.framesDropped, 0)
        XCTAssertGreaterThan(h.rateBps, 0)
        XCTAssertLessThan(p.hostStats.count, 6, "more than one a second")
    }

    // MARK: load

    /// A sampler that records how it is called and returns a fixed reading; `delay` makes a read slow.
    final class LoadProbe: @unchecked Sendable {
        private let lock = NSLock()  // guards pids, made
        private var pids: [Int32?] = []
        private var made = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return pids.count }
        var samplersMade: Int { lock.lock(); defer { lock.unlock() }; return made }
        var lastPID: Int32?? { lock.lock(); defer { lock.unlock() }; return pids.last }
        func record(_ pid: Int32?) { lock.lock(); pids.append(pid); lock.unlock() }
        func madeOne() { lock.lock(); made += 1; lock.unlock() }
    }

    struct FakeLoadSampler: LoadSampling {
        let probe: LoadProbe
        var delay: TimeInterval = 0
        mutating func sample(gamePID: Int32?, now: UInt64) -> MacLoadReading {
            probe.record(gamePID)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            var r = MacLoadReading()
            r.thermal = 1; r.pressure = 0; r.cpuTotal = 412; r.cpuPerf = 551; r.cpuEff = 120; r.gpu = 783
            r.memUsedMiB = 18_330; r.memTotalMiB = 32_768; r.gameAlive = true; r.gameCpuCentiCores = 160; r.gameMemMiB = 6_250
            return r
        }
    }

    private func loadService(delay: TimeInterval = 0) async throws -> LoadProbe {
        await service.stop()
        let probe = LoadProbe()
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        var config = HostConfig(name: "Test Host", storeURL: dir.appendingPathComponent("host-load.json"), libraryRoots: [],
                                launcher: launcher, power: power, advertise: false, port: 0, extraGames: [fake])
        config.silenceTimeout = 3
        config.loadSampler = { probe.madeOne(); return FakeLoadSampler(probe: probe, delay: delay) }
        service = try HostService(config: config)
        port = try await service.start()
        return probe
    }

    func testNothingIsSampledOrSentBelowFull() async throws {
        let probe = try await loadService()
        let p = try await livePeer("Phone")
        for level in [PanelLevel.off, .fps, .compact] {
            p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: level)))
            await sleep(0.3)
        }
        try await launchAndStream(p, frames: 20)
        await sleep(2.5)
        XCTAssertEqual(p.loads.count, 0)
        XCTAssertEqual(probe.calls, 0, "the sampler is not read")
        XCTAssertEqual(probe.samplersMade, 0, "nor made")
    }

    func testFullSendsOneWithinASecondAndAHalfThenOneASecond() async throws {
        let probe = try await loadService()
        let p = try await livePeer("Phone")
        try await launchAndStream(p, frames: 5)
        let start = Date()
        p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: .full)))
        let first = await p.wait(timeout: 1.2) { !p.loads.isEmpty }
        XCTAssertTrue(first, "the first load within 1.2 s")
        let inWindow = await p.wait(timeout: 3.3 - Date().timeIntervalSince(start)) { p.loads.count >= 4 }
        _ = inWindow
        await sleep(max(0, 3.3 - Date().timeIntervalSince(start)))
        let n = p.loads.filter { $0.at.timeIntervalSince(start) <= 3.4 }.count
        XCTAssertGreaterThanOrEqual(n, 3, "one a second: \(n) in 3.3 s")
        XCTAssertLessThanOrEqual(n, 4, "never faster than once a second: \(n)")
        let l = try XCTUnwrap(p.loads.last).load
        XCTAssertEqual(l.cpuTotal, 412); XCTAssertEqual(l.gpu, 783); XCTAssertTrue(l.gpuPresent); XCTAssertTrue(l.gameAlive)
        XCTAssertEqual(l.memTotalMiB, 32_768); XCTAssertEqual(l.gameCpuCentiCores, 160)
        XCTAssertNotNil(probe.lastPID, "the game's pid reaches the sampler")
        XCTAssertEqual(probe.samplersMade, 1, "one sampler for the whole stretch at full")
    }

    func testTheFrameFieldsAreTheGamesOwnFrames() async throws {
        _ = try await loadService()
        let p = try await livePeer("Phone")
        p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: .full)))
        try await launchAndStream(p, frames: 5)
        let got = await p.wait(timeout: 4) { p.loads.last.map { $0.load.gameFpsDeci > 0 } ?? false }
        XCTAssertTrue(got)
        let l = try XCTUnwrap(p.loads.last).load
        XCTAssertTrue((590...610).contains(Int(l.gameFpsDeci)), "60 fps from the capture times: \(l.gameFpsDeci)")
        XCTAssertTrue((150...185).contains(Int(l.frameMeanDeciMs)), "mean \(l.frameMeanDeciMs)")
        XCTAssertGreaterThanOrEqual(l.frameMaxDeciMs, l.frameP95DeciMs)
        XCTAssertGreaterThanOrEqual(l.frameP95DeciMs, l.frameMeanDeciMs - 20)
    }

    func testOffStopsItAtOnce() async throws {
        let probe = try await loadService()
        let p = try await livePeer("Phone")
        p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: .full)))
        try await launchAndStream(p, frames: 5)
        let got = await p.wait(timeout: 3) { p.loads.count >= 1 }
        XCTAssertTrue(got)
        p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: .off)))
        await sleep(0.4)
        let (n, calls) = (p.loads.count, probe.calls)
        await sleep(2.5)
        XCTAssertEqual(p.loads.count, n, "no load after off")
        XCTAssertEqual(probe.calls, calls, "no read after off")
    }

    func testAnEndedSessionStopsTheSampler() async throws {
        let probe = try await loadService()
        let p = try await livePeer("Phone")
        p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: .full)))
        try await launchAndStream(p, frames: 5)
        let got = await p.wait(timeout: 3) { probe.calls >= 1 }
        XCTAssertTrue(got)
        p.close()
        await sleep(0.6)
        let calls = probe.calls
        await sleep(2.5)
        XCTAssertEqual(probe.calls, calls, "nothing is read after the session ended")
    }

    /// A read that takes 1.5 s runs off the actor and the media path: the video does not stop meanwhile.
    func testASlowReadNeverDelaysVideo() async throws {
        let probe = try await loadService(delay: 1.5)
        let p = try await livePeer("Phone")
        p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: .full)))
        try await launchAndStream(p, frames: 5)
        let reading = await p.wait(timeout: 3) { probe.calls >= 2 }  // the priming read and the first (slow) one
        XCTAssertTrue(reading)
        let before = p.received.count
        let t0 = Date()
        await sleep(1.0)
        let frames = p.received.count - before
        XCTAssertGreaterThanOrEqual(frames, 40, "\(frames) frames in \(Date().timeIntervalSince(t0)) s while a read blocks")
    }

    // MARK: rate

    private func rates(_ log: [TapMessage]) -> [UInt32] {
        log.compactMap { if case let .config(_, _, _, b) = $0 { return b }; return nil }
    }

    /// A live peer wishing for 40 Mbit/s, streaming; the game's first config carries the wish.
    private func rateSession() async throws -> (ScriptedPeer, FakeGame) {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 40_000_000)
        let game = try await launchAndStream(p, frames: 5)
        XCTAssertEqual(rates(game.received), [40_000_000])
        await sleep(0.3)  // past the 250 ms between configs
        return (p, game)
    }

    /// `rate` reaches the game as a `config` of the same size and frame rate, clamped to [1 Mbit/s, the hello's wish].
    func testARateReachesTheGameClampedToTheWish() async throws {
        let (p, game) = try await rateSession()
        p.sendDatagram(.rate(bitsPerSecond: 25_000_000))
        var got = await waitGame(timeout: 1) { self.rates($0).last == 25_000_000 }
        XCTAssertTrue(got, "\(rates(game.received))")
        XCTAssertEqual(game.received.last { if case .config = $0 { true } else { false } },
                       .config(maxWidth: 1920, maxHeight: 1080, maxFps: 60, bitrate: 25_000_000))
        await sleep(0.3)
        p.sendDatagram(.rate(bitsPerSecond: 150_000_000))
        got = await waitGame(timeout: 1) { self.rates($0).last == 40_000_000 }
        XCTAssertTrue(got, "above the wish: \(rates(game.received))")
        await sleep(0.3)
        p.sendDatagram(.rate(bitsPerSecond: 10_000))
        got = await waitGame(timeout: 1) { self.rates($0).last == 1_000_000 }
        XCTAssertTrue(got, "under 1 Mbit/s: \(rates(game.received))")
    }

    /// A hundred rates 10 ms apart: at most 4 configs a second reach the game, and the newest wins (a cut sent just
    /// after an increase is what the game ends with, within 400 ms: the 250 ms between configs, then the 100 ms tick,
    /// since this peer sends nothing else that would apply it sooner).
    func testRatesReachTheGameAtMostFourTimesASecondNewestWins() async throws {
        let (p, game) = try await rateSession()
        let before = rates(game.received).count
        let start = Date()
        for i in 0..<100 {
            p.sendDatagram(.rate(bitsPerSecond: UInt32(20_000_000 + i * 100_000)))
            await sleep(0.01)
        }
        p.sendDatagram(.rate(bitsPerSecond: 35_000_000))
        p.sendDatagram(.rate(bitsPerSecond: 8_000_000))
        let sent = Date(), span = sent.timeIntervalSince(start)
        let got = await waitGame(timeout: 1) { self.rates($0).last == 8_000_000 }
        let after = Date().timeIntervalSince(sent)
        XCTAssertTrue(got, "the cut never came: \(rates(game.received))")
        XCTAssertLessThan(after, 0.4, "the cut came \(after) s after it was sent")
        let n = rates(game.received).count - before
        // One config per 250 ms of the span, plus the first at once and the cut at the end.
        XCTAssertLessThanOrEqual(n, Int(span * 4) + 2, "\(n) configs for 102 rates in \(span) s: \(rates(game.received))")
        XCTAssertGreaterThanOrEqual(n, 3, "rates were held back: \(rates(game.received))")
        await sleep(0.4)
        XCTAssertEqual(rates(game.received).last, 8_000_000, "an older rate came after the newest")
    }

    /// The sender's pacing rate, the resend budget and `hostStats.rateBps` follow the rate the game was given.
    func testTheSenderAndTheResendBudgetFollowTheRate() async throws {
        let (p, _) = try await rateSession()
        var sender = await service.sender.streamBitsPerSecond, budget = await service.resends.bitsPerSecond
        XCTAssertEqual(sender, 40_000_000)
        XCTAssertEqual(budget, 40_000_000)
        p.sendDatagram(.rate(bitsPerSecond: 12_000_000))
        let applied = await waitGame(timeout: 1) { self.rates($0).last == 12_000_000 }
        XCTAssertTrue(applied)
        sender = await service.sender.streamBitsPerSecond
        budget = await service.resends.bitsPerSecond
        XCTAssertEqual(sender, 12_000_000, "the pacing window still measures the old rate")
        XCTAssertEqual(budget, 12_000_000, "the resend budget still refills at the old rate")
        let reported = await p.wait(timeout: 2.5) { p.hostStats.last?.rateBps == 12_000_000 }
        XCTAssertTrue(reported, "hostStats say \(String(describing: p.hostStats.last?.rateBps))")
    }

    /// A key request that arrives while a rate waits out the 250 ms: the game gets the rate first, then the key frame
    /// (sized by the new rate).
    func testAPendingRateGoesToTheGameBeforeAKeyFrame() async throws {
        let (p, game) = try await rateSession()
        p.setAutoKeyRequest(false)
        p.sendDatagram(.rate(bitsPerSecond: 30_000_000))
        let first = await waitGame(timeout: 1) { self.rates($0).last == 30_000_000 }
        XCTAssertTrue(first)
        await sleep(0.11)  // past the key frame limit, inside the 250 ms between configs
        let mark = game.received.count
        p.sendDatagram(.rate(bitsPerSecond: 9_000_000))
        await sleep(0.01)
        p.sendDatagram(.keyRequest(lastGoodFrame: 0))
        let keyed = await waitGame(timeout: 1) { $0.dropFirst(mark).contains(.keyframe) }
        XCTAssertTrue(keyed)
        let tail = Array(game.received.dropFirst(mark))
        let cfg = tail.firstIndex(of: .config(maxWidth: 1920, maxHeight: 1080, maxFps: 60, bitrate: 9_000_000))
        let key = tail.firstIndex(of: .keyframe)
        XCTAssertNotNil(cfg, "the rate was not passed with the key request: \(rates(tail))")
        if let cfg, let key { XCTAssertLessThan(cfg, key, "the key frame was asked for before the rate") }
    }

    /// A padded fake game follows a later `config`: its frames take the new size from the next frame, with no key
    /// frame of their own, and the next key frame is 4 x the new size.
    func testAPaddedGameFollowsALaterRate() async throws {
        await service.stop()
        launcher = FakeLauncher(paddedToBitrate: true)
        service = try makeService()
        port = try await service.start()
        let (p, game) = try await rateSession()
        p.setAutoKeyRequest(false)
        let mark = p.received.count
        p.sendDatagram(.rate(bitsPerSecond: 10_000_000))
        let applied = await waitGame(timeout: 1) { self.rates($0).last == 10_000_000 }
        XCTAssertTrue(applied)
        _ = await p.wait(timeout: 2) { p.received.count >= mark + 30 }
        let after = Array(p.received.dropFirst(mark).map(\.frame))
        let small = after.suffix(10)
        XCTAssertTrue(small.allSatisfy { !$0.key && (19_000...22_500).contains($0.data.count) },
                      "frames at 10 Mbit/s: \(small.map { $0.data.count })")
        XCTAssertFalse(after.contains { $0.key }, "the rate change made a key frame")
        let before = p.received.count
        p.sendDatagram(.keyRequest(lastGoodFrame: 0))
        let keyed = await p.wait(timeout: 1) { p.received.dropFirst(before).contains { $0.frame.key } }
        XCTAssertTrue(keyed)
        let key = try XCTUnwrap(p.received.dropFirst(before).first { $0.frame.key }?.frame)
        XCTAssertTrue((80_000...86_000).contains(key.data.count), "a key frame at 10 Mbit/s: \(key.data.count) bytes")
        _ = game
    }

    /// A `rate` sealed for a welcomed session that is not the live one (the same device reconnecting, not yet admitted)
    /// changes nothing.
    func testARateFromASessionThatIsNotLiveIsIgnored() async throws {
        let (a, game) = try await rateSession()
        _ = a
        let again = peer("Phone", like: a)
        try again.connect(port: port)
        let reply = await again.hello(bitrate: 40_000_000)
        guard case .welcome? = reply else { return XCTFail("no welcome: \(String(describing: reply))") }
        try again.addSocket()
        for _ in 0..<5 { again.sendDatagram(.rate(bitsPerSecond: 5_000_000)); await sleep(0.05) }
        await sleep(0.4)  // a negative: the rate would have reached the game by now
        XCTAssertFalse(rates(game.received).contains(5_000_000), "\(rates(game.received))")
        let sender = await service.sender.streamBitsPerSecond
        XCTAssertEqual(sender, 40_000_000)
    }

    private func waitService(timeout: TimeInterval = 2, _ cond: @escaping (ResendStore.Refused) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let r = await service.resendRefused
            if cond(r) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let r = await service.resendRefused
        return cond(r)
    }

    func testAddressChange() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p)
        let second = try p.addSocket()
        p.sendDatagram(.ping(clientNs: 1), socket: second)
        let moved = await p.wait { p.received.filter { $0.socket == second }.count >= 5 }
        XCTAssertTrue(moved)

        let third = try p.addSocket(makeCurrent: false)
        p.sendRaw(p.forgedDatagram(), socket: third)
        p.sendRaw(Data(repeating: 0x22, count: 64), socket: third)
        let onSecond = p.received.filter { $0.socket == second }.count
        let more = await p.wait { p.received.filter { $0.socket == second }.count >= onSecond + 10 }
        XCTAssertTrue(more)
        XCTAssertEqual(p.datagrams(socket: third), 0)
    }

    // MARK: session rules

    func testSecondDeviceBusy() async throws {
        let a = try await livePeer("Phone")
        try await launchAndStream(a)
        let b = try await pairedPeer("Tablet")
        let reply = await b.hello()
        XCTAssertEqual(reply, .refuse(.busy(device: "Phone")))
        let closed = await b.waitClosed()
        XCTAssertTrue(closed)
        let n = a.received.count
        let more = await a.wait { a.received.count >= n + 10 }
        XCTAssertTrue(more)
    }

    func testSilencePausesAndResumes() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.setSilent(true)
        await sleep(3.5)
        XCTAssertTrue(game.received.contains(.pause(true)))
        XCTAssertFalse(game.received.contains(.pause(false)))

        let again = peer("Phone", like: a)
        try await again.open(port: port)
        let resumed = await waitGame { log in
            guard let p = log.lastIndex(of: .pause(true)) else { return false }
            return log[p...].contains(.pause(false))
        }
        XCTAssertTrue(resumed)
        let keyed = await again.wait { again.received.first?.frame.key == true }
        XCTAssertTrue(keyed, "frames \(again.received.count)")
    }

    func testPausedGameMediaNotRelayed() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.setSilent(true)
        let paused = await waitGame(timeout: 5) { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)

        let b = try await livePeer("Tablet")
        await sleep(0.5)  // a negative: the paused game's sound must not reach the new device
        XCTAssertEqual(b.received.count, 0)
        XCTAssertEqual(b.audio.count, 0)
        XCTAssertFalse(game.received.contains(.pause(false)))

        b.send(.resume)
        let both = await b.wait { b.received.count >= 1 && b.audio.count >= 1 }
        XCTAssertTrue(both, "frames \(b.received.count), audio \(b.audio.count)")
    }

    func testSizeCapClamped() async throws {
        func configs(_ log: [TapMessage]) -> [[UInt16]] {
            log.compactMap { if case let .config(w, h, _, _) = $0 { return [w, h] }; return nil }
        }
        let a = try await pairedPeer("Phone")
        try await a.open(port: port, maxWidth: 0, maxHeight: 0)
        a.send(.launch(titleID: fakeID))
        let first = await waitGame { !configs($0).isEmpty }
        XCTAssertTrue(first)
        XCTAssertEqual(configs(tapLog).last, [320, 180])

        a.close()
        let again = peer("Phone", like: a)
        try await again.open(port: port, maxWidth: 1281, maxHeight: 721)
        let second = await waitGame { configs($0).last == [1280, 720] }
        XCTAssertTrue(second, "\(configs(tapLog))")
    }

    func testTakeOverNeedsResume() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        a.setSilent(true)
        let paused = await waitGame(timeout: 5) { $0.contains(.pause(true)) }
        XCTAssertTrue(paused)

        let b = try await livePeer("Tablet")
        b.send(.listRequest)
        guard case let .list(entries)? = await b.next({ if case .list = $0 { true } else { false } }) else {
            return XCTFail("no list")
        }
        XCTAssertEqual(entries.first?.state, .paused)
        await sleep(0.5)  // a negative: no resume without the new device asking
        XCTAssertFalse(game.received.contains(.pause(false)))

        b.send(.resume)
        let resumed = await waitGame { $0.contains(.pause(false)) }
        XCTAssertTrue(resumed)
        let frames = await b.wait { b.received.count >= 5 }
        XCTAssertTrue(frames)
    }

    func testReconnectOldCloseIgnored() async throws {
        let a = try await livePeer("Phone")
        let game = try await launchAndStream(a)
        let mark = game.received.count

        let again = peer("Phone", like: a)
        try await again.open(port: port)
        let pump = Task {
            while !Task.isCancelled {
                again.sendInput(buttons: 1)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let oldClosed = await a.waitClosed()
        XCTAssertTrue(oldClosed, "the replaced connection is closed")
        a.closeControl()
        await sleep(1)  // a negative: the old close must not detach the new session
        let after = Array(game.received[mark...])
        XCTAssertFalse(after.contains(.pause(true)))
        XCTAssertFalse(after.contains(.motionClear(player: 0)))
        XCTAssertFalse(pads(after).contains(0))
        let n = again.received.count
        let more = await again.wait { again.received.count >= n + 10 }
        XCTAssertTrue(more)

        pump.cancel()
        again.setSilent(true)
        let paused = await waitGame(timeout: 5) { $0[mark...].contains(.pause(true)) }
        XCTAssertTrue(paused, "silence on the new connection still pauses")
    }

    // MARK: games

    func testQuitGame() async throws {
        let p = try await livePeer("Phone")
        let game = try await launchAndStream(p)
        p.send(.quitGame)
        let quit = await waitGame { $0.contains(.quit) }
        XCTAssertTrue(quit)
        let idle = await p.next { $0.gameState?.run == .idle }
        XCTAssertNotNil(idle)
        XCTAssertTrue(game.isFinished)
    }

    func testLaunchWhileRunning() async throws {
        let p = try await livePeer("Phone")
        try await launchAndStream(p)
        p.send(.launch(titleID: fakeID))
        let state = await p.next { $0.gameState?.reason != nil }
        XCTAssertTrue(state?.gameState?.reason?.contains("is running") == true, "\(String(describing: state))")
        XCTAssertEqual(state?.gameState?.run, .running)
        let n = p.received.count
        let more = await p.wait { p.received.count >= n + 10 }
        XCTAssertTrue(more)
    }

    func testGameExit() async throws {
        let p = try await livePeer("Phone")
        let game = try await launchAndStream(p)
        game.stop(exitCode: 7)
        let exited = await p.next { $0.gameState?.run == .idle }
        XCTAssertEqual(exited?.gameState?.reason, "exited (7)")
        try await launchAndStream(p)
        XCTAssertFalse(launcher.game === game)
    }

    func testSlowStartWithinTimeoutGoesLive() async throws {
        await service.stop()
        launcher = FakeLauncher(connectDelay: 1.5)
        service = try makeService(startTimeout: 3)
        port = try await service.start()
        let p = try await livePeer("Phone")
        p.send(.launch(titleID: fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running, "no running state")
        let states = p.messages.compactMap(\.gameState)
        XCTAssertEqual(states.map(\.run).filter { $0 != .idle }.first, .starting)
        XCTAssertFalse(states.contains { $0.reason == "did not start" })
    }

    func testNeverConnectingGameAbandonedAfterTimeout() async throws {
        await service.stop()
        let silent = SilentLauncher()
        service = try HostService(config: HostConfig(
            name: "Test Host", storeURL: dir.appendingPathComponent("host2.json"), libraryRoots: [],
            launcher: silent, power: power, advertise: false, port: 0,
            extraGames: [GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"),
                                 streamable: true)],
            startTimeout: 1))
        port = try await service.start()
        let p = try await livePeer("Phone")
        let start = Date()
        p.send(.launch(titleID: fakeID))
        let failed = await p.next { $0.gameState?.reason == "did not start" }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(failed, "no did-not-start state")
        XCTAssertEqual(failed?.gameState?.run, .idle)
        XCTAssertGreaterThanOrEqual(elapsed, 1)
        XCTAssertLessThan(elapsed, 4)
        let ended = await waitUntil(timeout: 2) { silent.terminated }
        XCTAssertTrue(ended, "process not terminated")
    }

    private func restart(with launcher: DetachedLauncher) async throws {
        await service.stop()
        service = try HostService(config: HostConfig(
            name: "Test Host", storeURL: dir.appendingPathComponent("host3.json"), libraryRoots: [],
            launcher: launcher, power: power, advertise: false, port: 0,
            extraGames: [GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"),
                                 streamable: true)]))
        port = try await service.start()
    }

    /// The process exits while its game is still connected: the game is cut off and the next launch runs.
    func testExitedProcessLeftoverDisconnected() async throws {
        let detached = DetachedLauncher()
        try await restart(with: detached)
        let p = try await livePeer("Phone")
        p.send(.launch(titleID: fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running, "no running state")
        let first = try XCTUnwrap(detached.games.first)
        defer { for g in detached.games { g.stop() } }

        detached.reportExit(0)
        let exited = await p.next { $0.gameState?.run == .idle }
        XCTAssertEqual(exited?.gameState?.reason, "exited (137)")
        let cut = await waitUntil(timeout: 2) { first.isFinished }
        XCTAssertTrue(cut, "the leftover game still holds the tap connection")

        p.send(.launch(titleID: fakeID))
        let again = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(again, "second launch never ran")
        XCTAssertEqual(detached.games.count, 2)
    }

    /// The game closes the tap but its process stays: terminated after the quit grace.
    func testTapClosedWithoutExitTerminates() async throws {
        let detached = DetachedLauncher()
        detached.obeyTerminate = true
        try await restart(with: detached)
        let p = try await livePeer("Phone")
        p.send(.launch(titleID: fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running, "no running state")
        let game = try XCTUnwrap(detached.games.first)
        let start = Date()
        game.stop()
        let idle = await p.next(timeout: 8) { $0.gameState?.run == .idle }
        XCTAssertNotNil(idle, "process never terminated")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), HostService.quitGrace - 0.5)
        XCTAssertEqual(detached.terminations, 1)
    }

    func testDefaultStartTimeout() {
        let config = HostConfig(
            name: "n", storeURL: dir, libraryRoots: [], launcher: launcher, power: power, advertise: false, port: 0)
        XCTAssertEqual(config.startTimeout, 600)
    }

    func testStopEndsGame() async throws {
        let p = try await livePeer("Phone")
        let game = try await launchAndStream(p)
        await service.stop()
        let ended = await waitUntil(timeout: 2) { game.isFinished }
        XCTAssertTrue(ended)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }
}

// MARK: artwork -> .claude/host.md § library

extension HostServiceTests {
    private static let artID = "FAKE0000000000A1"

    /// The service again, with one more game whose icon is drawn by `FakeArt` in the test's folder.
    private func serviceWithArt(_ paint: FakeArt.Paint = .noise(seed: 3)) async throws -> URL {
        let app = try FakeArt.makeApp(in: dir.appendingPathComponent("lib"), titleID: Self.artID, name: "Art Game", paint: paint)
        await service.stop()
        service = try makeService(extraGames: [GameApp(titleID: Self.artID, name: "Art Game", url: app, streamable: true)])
        port = try await service.start()
        return app
    }

    private func list(_ p: ScriptedPeer) async throws -> [GameEntry] {
        p.send(.listRequest)
        guard case let .list(games)? = await p.next({ if case .list = $0 { true } else { false } }) else { throw PeerError.noReply("list") }
        return games
    }

    private struct Chunk: Equatable { var index: UInt16, count: UInt16, bytes: Data }

    /// The `art` replies for `titleID`, in arrival order, until the last chunk (or `count` 0).
    private func chunks(_ p: ScriptedPeer, _ titleID: String, timeout: TimeInterval = 5) async -> [Chunk] {
        var out: [Chunk] = []
        while let m = await p.next(timeout: timeout, { if case let .art(t, _, _, _, _) = $0 { t == titleID } else { false } }) {
            guard case let .art(_, _, index, count, bytes) = m else { break }
            out.append(Chunk(index: index, count: count, bytes: bytes))
            if count == 0 || index + 1 >= count { break }
        }
        return out
    }

    func testTheListCarriesArtOnlyForAGameWithAnIcon() async throws {
        let app = try await serviceWithArt()
        let p = try await livePeer("Phone")
        let games = try await list(p)
        let png = try XCTUnwrap(GameArtwork.png(forBundle: app))
        XCTAssertEqual(games.first { $0.titleID == Self.artID }?.art, ArtRef(hash: GameArtwork.hash(png), bytes: UInt32(png.count)))
        XCTAssertNil(games.first { $0.titleID == fakeID }?.art)
    }

    func testAnArtRequestIsAnsweredInOrderedChunksThatHashToIt() async throws {
        _ = try await serviceWithArt()
        let p = try await livePeer("Phone")
        let listed = try await list(p)
        let ref = try XCTUnwrap(listed.first { $0.titleID == Self.artID }?.art)
        p.send(.artRequest(titleID: Self.artID, hash: ref.hash))
        let got = await chunks(p, Self.artID)
        let expected = (Int(ref.bytes) + 49_151) / 49_152
        XCTAssertGreaterThan(expected, 1, "the test icon spans several chunks")
        XCTAssertEqual(got.map(\.index), (0..<expected).map(UInt16.init))
        XCTAssertTrue(got.allSatisfy { Int($0.count) == expected })
        XCTAssertTrue(got.allSatisfy { $0.bytes.count <= 49_152 })
        let whole = got.reduce(Data()) { $0 + $1.bytes }
        XCTAssertEqual(whole.count, Int(ref.bytes))
        XCTAssertEqual(GameArtwork.hash(whole), ref.hash)
    }

    func testAnUnknownHashOrTitleGetsCountZero() async throws {
        _ = try await serviceWithArt()
        let p = try await livePeer("Phone")
        _ = try await list(p)
        p.send(.artRequest(titleID: Self.artID, hash: String(repeating: "0", count: 64)))
        let noneForAnUnknownHash = await chunks(p, Self.artID)
        XCTAssertEqual(noneForAnUnknownHash, [Chunk(index: 0, count: 0, bytes: Data())])
        p.send(.artRequest(titleID: "FAKE0000000000ZZ", hash: String(repeating: "0", count: 64)))
        let noneForAnUnknownTitle = await chunks(p, "FAKE0000000000ZZ")
        XCTAssertEqual(noneForAnUnknownTitle, [Chunk(index: 0, count: 0, bytes: Data())])
        p.send(.artRequest(titleID: fakeID, hash: String(repeating: "0", count: 64)))
        let noneForAGameWithoutIcon = await chunks(p, fakeID)
        XCTAssertEqual(noneForAGameWithoutIcon, [Chunk(index: 0, count: 0, bytes: Data())], "a game without an icon")
    }

    /// A request with a title ID over 64 bytes or a hash that is not 64 characters is dropped: nothing is queued, no reply
    /// (an echo of a large string would pass the sealed cap and end the session), and the link goes on.
    func testAMalformedArtRequestIsDroppedAndTheSessionStays() async throws {
        _ = try await serviceWithArt()
        let p = try await livePeer("Phone")
        let listed = try await list(p)
        let ref = try XCTUnwrap(listed.first { $0.titleID == Self.artID }?.art)
        let good = String(repeating: "0", count: 64)
        p.send(.artRequest(titleID: String(repeating: "T", count: 500_000), hash: good))
        for length in [63, 65] { p.send(.artRequest(titleID: Self.artID, hash: String(repeating: "0", count: length))) }
        p.send(.artRequest(titleID: String(repeating: "T", count: 65), hash: good))
        await sleep(0.6)
        XCTAssertEqual(p.messages.filter { if case .art = $0 { true } else { false } }.count, 0, "a malformed ask was answered")
        let taken = await service.artMessagesTaken
        XCTAssertEqual(taken, 0)
        let again = try await list(p)  // the session is alive
        XCTAssertEqual(again.count, listed.count)
        p.send(.artRequest(titleID: String(repeating: "T", count: 64), hash: good))  // 64 bytes is the limit and allowed
        let none = await chunks(p, String(repeating: "T", count: 64))
        XCTAssertEqual(none, [Chunk(index: 0, count: 0, bytes: Data())])
        p.send(.artRequest(titleID: Self.artID, hash: ref.hash))
        let got = await chunks(p, Self.artID)
        XCTAssertFalse(got.isEmpty)
    }

    /// The slots are shared by every link: six takers at once, four hold a slot, the others wait for a release.
    func testSixTakersShareFourTransferSlots() async throws {
        let served = ArtSlotTally()
        let svc = try XCTUnwrap(service)
        let takers = (0..<6).map { _ in Task { await svc.takeArtSlot(); served.add() } }
        let four = await waitUntil { served.count == 4 }
        XCTAssertTrue(four, "\(served.count) takers hold a slot, expected 4")
        await sleep(0.2)
        XCTAssertEqual(served.count, 4, "a fifth taker got a slot")
        var transfers = await service.artTransfers
        XCTAssertEqual(transfers, 4)
        await service.releaseArtSlot()
        let five = await waitUntil { served.count == 5 }
        XCTAssertTrue(five)
        await service.releaseArtSlot()
        let six = await waitUntil { served.count == 6 }
        XCTAssertTrue(six)
        transfers = await service.artTransfers
        XCTAssertEqual(transfers, 4, "a slot handed to a waiter stays counted")
        for _ in 0..<4 { await service.releaseArtSlot() }
        transfers = await service.artTransfers
        XCTAssertEqual(transfers, 0)
        for t in takers { _ = await t.value }
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; await sleep(0.01) }
        return cond()
    }

    func testAHundredRequestsAreAllAnsweredWithAtMostFourTransfersAtOnce() async throws {
        _ = try await serviceWithArt()
        let p = try await livePeer("Phone")
        let listed = try await list(p)
        let ref = try XCTUnwrap(listed.first { $0.titleID == Self.artID }?.art)
        let start = Date()
        for i in 0..<100 {
            p.send(.artRequest(titleID: Self.artID, hash: i % 10 == 9 ? String(repeating: "0", count: 64) : ref.hash))
            try? await Task.sleep(nanoseconds: 9_000_000)
        }
        let done = await p.wait(timeout: 5) {
            p.messages.filter { if case let .art(_, _, index, count, _) = $0 { count == 0 || index + 1 == count } else { false } }.count >= 100
        }
        XCTAssertTrue(done, "answered \(p.messages.filter { if case .art = $0 { true } else { false } }.count) chunks")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        let peak = await service.artTransfersPeak
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThanOrEqual(peak, HostService.maxArtTransfers)
        XCTAssertEqual(HostService.maxArtTransfers, 4)
    }

    func testADeviceThatDoesNotReadHoldsTheHostToWhatItsConnectionTakes() async throws {
        _ = try await serviceWithArt()
        let p = try await livePeer("Phone")
        let listed = try await list(p)
        let ref = try XCTUnwrap(listed.first { $0.titleID == Self.artID }?.art)
        let perIcon = (Int(ref.bytes) + 49_151) / 49_152
        p.setReading(false)
        for _ in 0..<(HostService.maxArtQueue + 50) { p.send(.artRequest(titleID: Self.artID, hash: ref.hash)) }
        await sleep(1.5)
        let taken = await service.artMessagesTaken
        let asked = HostService.maxArtQueue * perIcon
        XCTAssertLessThan(taken, asked / 2, "taken \(taken) of \(asked): the Host kept sending to a device that does not read")
        p.setReading(true)
        let drained = await p.wait(timeout: 10) {
            p.messages.filter { if case let .art(_, _, index, count, _) = $0 { index + 1 == count } else { false } }.count >= HostService.maxArtQueue
        }
        XCTAssertTrue(drained, "the queued requests are answered once the device reads")
    }

    func testANewIconFileGetsANewHashOnTheNextList() async throws {
        let app = try await serviceWithArt(.flat(0x3366FF))
        let p = try await livePeer("Phone")
        let before = try await list(p)
        let first = try XCTUnwrap(before.first { $0.titleID == Self.artID }?.art)
        let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        try FakeArt.write(FakeArt.image(.flat(0xFF3300), side: 1024), to: icon)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: icon.path)
        let after = try await list(p)
        let second = try XCTUnwrap(after.first { $0.titleID == Self.artID }?.art)
        XCTAssertNotEqual(second.hash, first.hash)
        let kept = await service.artwork(titleID: Self.artID)
        XCTAssertEqual(kept.map(GameArtwork.hash), second.hash, "one read of the kept icon")
    }
    // MARK: live settings (network 4)

    /// A rate of `want` is applied as `expect` (the last config the game got).
    private func assertRate(_ p: ScriptedPeer, _ game: FakeGame, want: UInt32, expect: UInt32, _ why: String) async {
        await sleep(0.3)  // past the 250 ms between configs
        p.sendDatagram(.rate(bitsPerSecond: want))
        let got = await waitGame(timeout: 1) { self.rates($0).last == expect }
        XCTAssertTrue(got, "\(why): \(rates(game.received))")
    }

    private func waitLive(timeout: TimeInterval = 2, _ cond: @escaping (LiveSettings?) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(await service.liveSettings()) { return true }
            await sleep(0.01)
        }
        return cond(await service.liveSettings())
    }

    /// After `liveSettings(ceilingBps: 30 Mbit/s)` a rate of 50 is applied as 30, though the hello wished for 60.
    func testALiveCeilingReplacesTheHellosWish() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 60_000_000)
        let game = try await launchAndStream(p, frames: 5)
        await assertRate(p, game, want: 50_000_000, expect: 50_000_000, "under the wish")
        p.send(.liveSettings(LiveSettings(ceilingBps: 30_000_000, panel: nil)))
        let seen = await waitLive { $0?.ceilingBps == 30_000_000 }
        XCTAssertTrue(seen)
        await assertRate(p, game, want: 55_000_000, expect: 30_000_000, "over the live ceiling")
        let live = await service.liveSettings()
        XCTAssertEqual(live, LiveSettings(ceilingBps: 30_000_000, panel: nil))
        // Raised again: the wish no longer caps it.
        p.send(.liveSettings(LiveSettings(ceilingBps: 90_000_000, panel: .full)))
        await assertRate(p, game, want: 80_000_000, expect: 80_000_000, "raised above the hello's wish")
        let raised = await service.liveSettings()
        XCTAssertEqual(raised, LiveSettings(ceilingBps: 90_000_000, panel: .full))
    }

    /// An enormous ceiling clamps to the Host's maximum.
    func testALiveCeilingIsClampedToTheHostsMaximum() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 40_000_000)
        let game = try await launchAndStream(p, frames: 5)
        p.send(.liveSettings(LiveSettings(ceilingBps: UInt32.max, panel: nil)))
        await assertRate(p, game, want: UInt32.max, expect: HostDefaults.maxBitrate, "above the maximum")
        let live = await service.liveSettings()
        XCTAssertEqual(live?.ceilingBps, HostDefaults.maxBitrate)
        p.send(.liveSettings(LiveSettings(ceilingBps: 10, panel: nil)))
        await assertRate(p, game, want: 50_000_000, expect: HostDefaults.minBitrate, "a tiny ceiling stays at the 1 Mbit/s floor")
    }

    /// The Host is the authority on the ceiling: lowering it under the running rate reaches the game's encoder at once,
    /// with no `rate` datagram from the client afterwards.
    func testALoweredCeilingReachesTheEncoderWithoutAClientRate() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 60_000_000)
        let game = try await launchAndStream(p, frames: 5)
        await assertRate(p, game, want: 50_000_000, expect: 50_000_000, "the running rate")
        await sleep(0.3)
        p.send(.liveSettings(LiveSettings(ceilingBps: 20_000_000, panel: nil)))
        let cut = await waitGame(timeout: 1) { self.rates($0).last == 20_000_000 }
        XCTAssertTrue(cut, "no rate sent after the lowering: \(rates(game.received))")
        // a ceiling above the running rate sends no config
        let before = rates(game.received).count
        p.send(.liveSettings(LiveSettings(ceilingBps: 80_000_000, panel: nil)))
        await sleep(0.4)
        XCTAssertEqual(rates(game.received).count, before, "a raised ceiling changes nothing now")
    }

    /// A raise waiting for the 250 ms interval never passes a ceiling lowered meanwhile: encoder at 40, a `rate` of 50
    /// queued, then a ceiling of 45 -> no config above 45 reaches the game.
    func testAQueuedRaiseNeverPassesALoweredCeiling() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 60_000_000)
        let game = try await launchAndStream(p, frames: 5)
        await assertRate(p, game, want: 40_000_000, expect: 40_000_000, "the running rate")
        let before = rates(game.received).count
        p.sendDatagram(.rate(bitsPerSecond: 50_000_000))  // inside the 250 ms: queued
        p.send(.liveSettings(LiveSettings(ceilingBps: 45_000_000, panel: nil)))
        let lowered = await waitLive { $0?.ceilingBps == 45_000_000 }
        XCTAssertTrue(lowered)
        for _ in 0..<8 {  // datagrams and ticks past the interval would release a queued rate
            p.sendInput(buttons: 0)
            await sleep(0.1)
        }
        let over = rates(game.received).dropFirst(before).filter { $0 > 45_000_000 }
        XCTAssertTrue(over.isEmpty, "a queued raise passed the lowered ceiling: \(rates(game.received))")
    }

    /// A ceiling of 0 is ignored (the panel part of the message still applies).
    func testALiveCeilingOfZeroChangesNothing() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 40_000_000)
        let game = try await launchAndStream(p, frames: 5)
        p.send(.liveSettings(LiveSettings(ceilingBps: 0, panel: .compact)))
        await assertRate(p, game, want: 150_000_000, expect: 40_000_000, "still the hello's wish")
        let live = await service.liveSettings()
        XCTAssertEqual(live, LiveSettings(ceilingBps: nil, panel: .compact))
    }

    /// A message with neither field changes nothing and keeps the connection.
    func testAnEmptyLiveSettingsIsHarmless() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 40_000_000)
        p.send(.liveSettings(LiveSettings(ceilingBps: 20_000_000, panel: .fps)))
        p.send(.liveSettings(LiveSettings(ceilingBps: nil, panel: nil)))
        p.send(.listRequest)
        let list = await p.next({ if case .list = $0 { true } else { false } })
        XCTAssertNotNil(list, "the connection stays open")
        let live = await service.liveSettings()
        XCTAssertEqual(live, LiveSettings(ceilingBps: 20_000_000, panel: .fps), "an empty message leaves what was set")
    }

    /// Before admission (`ready`) the connection is closed.
    func testALiveSettingsBeforeAdmissionClosesTheConnection() async throws {
        let p = try await pairedPeer("Phone")
        guard case .welcome? = await p.hello() else { return XCTFail("no welcome") }
        p.send(.liveSettings(LiveSettings(ceilingBps: 30_000_000, panel: .full)))
        let closed = await p.waitClosed()
        XCTAssertTrue(closed)
        let live = await service.liveSettings()
        XCTAssertNil(live)
    }

    /// The tap's next `config` (the game connecting after the message) uses the new ceiling.
    func testTheNextTapConfigUsesTheLiveCeiling() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 20_000_000)
        p.send(.liveSettings(LiveSettings(ceilingBps: 35_000_000, panel: nil)))
        let game = try await launchAndStream(p, frames: 5)
        XCTAssertEqual(rates(game.received), [35_000_000], "the game's first config carries the live ceiling")
    }

    /// A new session starts with no live settings of its own.
    func testLiveSettingsDoNotOutliveTheSession() async throws {
        let p = try await pairedPeer("Phone")
        try await p.open(port: port, bitrate: 40_000_000)
        p.send(.liveSettings(LiveSettings(ceilingBps: 20_000_000, panel: .full)))
        let during = await waitLive { $0 != nil && $0 != LiveSettings(ceilingBps: nil, panel: nil) }
        XCTAssertTrue(during)
        p.close()
        let gone = await waitLive { $0 == nil }
        XCTAssertTrue(gone, "the session is over")
        let q = try await pairedPeer("Tablet")
        try await q.open(port: port, bitrate: 40_000_000)
        let fresh = await waitLive { $0 == LiveSettings(ceilingBps: nil, panel: nil) }
        XCTAssertTrue(fresh, "the new session has no live settings of its own")
    }
}

/// Counts takers that got a transfer slot.
final class ArtSlotTally: @unchecked Sendable {  // guarded by the lock
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
#endif
