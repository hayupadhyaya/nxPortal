#if os(macOS)
import XCTest
import Foundation
import Network
import PortalKit
import PortalTestSupport
@testable import PortalHostCore

/// A clock the test moves.
private final class AdminClock: @unchecked Sendable {
    private let lock = NSLock()  // guards t
    private var t = Date(timeIntervalSinceReferenceDate: 1_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

/// A launcher that cannot start the game.
private struct ThrowingLauncher: GameLaunching {
    struct Failure: Error {}
    func launch(titleID: String, socketPath: String) async throws -> any RunningGame { throw Failure() }
}

/// A game whose tap `hello` speaks another version.
private final class WrongVersionLauncher: GameLaunching, @unchecked Sendable {
    func launch(titleID: String, socketPath: String) async throws -> any RunningGame {
        let g = FakeGame(socketPath: socketPath, titleID: titleID, version: ProtocolVersion.tap + 1)
        let task = Task<Int32, Never> { do { try await g.run(); return g.exitCode } catch { return 1 } }
        return WrongVersionGame(game: g, task: task)
    }
}

private struct WrongVersionGame: RunningGame {
    let game: FakeGame
    let task: Task<Int32, Never>
    func terminate() async { game.stop(exitCode: 15) }
    func waitForExit() async -> Int32 { await task.value }
}

/// A game process that ignores SIGTERM and never opens the tap (so it also ignores the quit that closing the tap gives).
private struct StubbornLauncher: GameLaunching {
    let script: URL
    func launch(titleID: String, socketPath: String) async throws -> any RunningGame {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let game = RunningProcess(process, killGrace: 0.3)
        try game.start()
        return game
    }
}

/// A secret store whose writes can be made to fail.
private final class FlakySecrets: SecretStoring, @unchecked Sendable {
    struct WriteFailed: Error {}
    private let inner = MemorySecrets()
    private let lock = NSLock()  // guards failing
    private var failing = false
    var failWrites: Bool { get { lock.withLock { failing } } set { lock.withLock { failing = newValue } } }
    func read(_ key: String) throws -> Data? { try inner.read(key) }
    func write(_ key: String, _ data: Data) throws {
        if failWrites { throw WriteFailed() }
        try inner.write(key, data)
    }
    func delete(_ key: String) throws { try inner.delete(key) }
}

/// What the Host app calls: devices, folders, quit and pairing -> .claude/host.md § admin
final class HostAdminTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private var dir: URL!
    private var service: HostService!
    private var port: UInt16 = 0
    private var launcher: FakeLauncher!
    private var peers: [ScriptedPeer] = []
    private var extraServices: [HostService] = []

    override func setUp() async throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-a-" + UUID().uuidString)
        launcher = FakeLauncher()
    }

    override func tearDown() async throws {
        for p in peers { p.close() }
        await service?.stop()
        for s in extraServices { await s.stop() }
        launcher.game?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    private var fake: GameApp { GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true) }

    /// Replaces `service` with a started one.
    private func start(launcher custom: (any GameLaunching)? = nil, extra: [GameApp]? = nil, roots: [URL] = [],
                       clock: (@Sendable () -> Date)? = nil, secrets: (any SecretStoring)? = nil, name: String = "Test Host",
                       advertise: Bool = false, environment: (@Sendable (String) -> [String: String])? = nil,
                       defaultBitrate: UInt32? = nil, maxBitrate: UInt32? = nil) async throws {
        await service?.stop()
        var config = HostConfig(name: name, storeURL: dir.appendingPathComponent("host.json"), libraryRoots: roots,
                                launcher: custom ?? launcher, power: NoPower(), advertise: advertise, port: 0,
                                extraGames: extra ?? [fake])
        if let clock { config.clock = clock }
        config.secrets = secrets
        if let environment { config.gameEnvironment = environment }
        if let defaultBitrate { config.defaultBitrate = defaultBitrate }
        if let maxBitrate { config.maxBitrate = maxBitrate }
        service = try HostService(config: config)
        port = try await service.start()
    }

    private func peer(_ name: String, like other: ScriptedPeer? = nil) -> ScriptedPeer {
        let p = ScriptedPeer(identity: other?.identity ?? Identity(), name: name)
        if let key = other?.hostKey { p.trust(hostKey: key) }
        peers.append(p)
        return p
    }

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

    /// The measured frame rate leaves 3 s after its measure, and a gap over 2 s between frames starts the measure afresh.
    func testTheMeasuredFrameRateExpiresAfterThreeSecondsAndRestartsAfterATwoSecondGap() async throws {
        try await start()
        let ms: UInt64 = 1_000_000
        let base: UInt64 = 10_000_000_000
        func frames(from t0: UInt64, count: Int) async -> UInt64 {  // 50 fps: one frame each 20 ms of capture and arrival
            var t = t0
            for _ in 0..<count { await service.noteFrameRate(captureNs: t, nowNs: t); t += 20 * ms }
            return t
        }
        var none = await service.reportedFps(atNs: base)
        XCTAssertNil(none, "nothing measured yet")
        let end = await frames(from: base, count: 80)  // 1.6 s: one measure after the first second
        let measuredAt = await service.fpsMeasuredNs
        XCTAssertGreaterThan(measuredAt, 0)
        var fps = await service.reportedFps(atNs: measuredAt + 2_900 * ms)
        XCTAssertEqual(fps, 50, "within 3 s of the measure")
        none = await service.reportedFps(atNs: measuredAt + 3_100 * ms)
        XCTAssertNil(none, "3 s after the measure and no newer one: unknown, never a stale number")
        // a gap just under 2 s keeps the measure going; one over 2 s drops it and starts afresh
        let resumed = await frames(from: end + 1_900 * ms, count: 1)
        fps = await service.reportedFps(atNs: resumed)
        XCTAssertNotNil(fps, "a 1.9 s gap is not a restart: the slow gap is measured, not dropped")
        XCTAssertLessThan(fps ?? 50, 50, "and it shows as the slower rate it is")
        let end2 = await frames(from: resumed + 2_100 * ms, count: 1)
        none = await service.reportedFps(atNs: end2)
        XCTAssertNil(none, "a gap over 2 s: the measure is dropped")
        _ = await frames(from: end2, count: 80)
        let again = await service.fpsMeasuredNs
        XCTAssertGreaterThan(again, measuredAt, "and measured afresh from the new frames")
    }

    private func poll(timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func launchAndStream(_ p: ScriptedPeer, _ titleID: String? = nil) async throws {
        let before = p.received.count
        p.send(.launch(titleID: titleID ?? fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running, "no running state")
        let streaming = await p.wait { p.received.count >= before + 3 }
        XCTAssertTrue(streaming)
    }

    private func makeBundle(in root: URL, _ relative: String, titleID: String, name: String) throws {
        let contents = root.appendingPathComponent(relative).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["DMTitleID": titleID, "DMStream": true, "CFBundleName": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    // MARK: devices

    func testDevicesListsPairedAndLive() async throws {
        try await start()
        let before = await service.devices()
        XCTAssertEqual(before, [])
        let phone = try await livePeer("Phone")
        let tablet = try await pairedPeer("Tablet")
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.name), ["Phone", "Tablet"], "sorted by name")
        XCTAssertEqual(devices.map(\.live), [true, false])
        XCTAssertEqual(devices.map(\.id), [phone.identity.publicKey, tablet.identity.publicKey])
    }

    func testRemoveLiveDeviceEndsItsSession() async throws {
        try await start()
        let a = try await livePeer("Phone")
        let b = try await pairedPeer("Tablet")
        try await launchAndStream(a)
        let game = try XCTUnwrap(launcher.game)
        let start = Date()
        try await service.removeDevice(a.identity.publicKey)
        let bye = await a.next(timeout: 1) { $0 == .bye() }
        XCTAssertNotNil(bye, "no sealed bye")
        let closed = await a.waitClosed(timeout: 1)
        XCTAssertTrue(closed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        let paused = await poll { game.received.contains(.pause(true)) }
        XCTAssertTrue(paused, "the game was not paused")
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.name), ["Tablet"])

        let again = peer("Phone", like: a)
        do {
            try await again.open(port: port)
            XCTFail("a removed device opened")
        } catch PeerError.refused(let r) {
            XCTAssertEqual(r, .unpaired)
        }

        try await b.open(port: port)
        b.send(.resume)
        let resumed = await poll { game.received.contains(.pause(false)) }
        XCTAssertTrue(resumed, "the second device could not resume")
    }

    /// A device that is welcomed but not yet admitted is cut off too.
    func testRemoveADeviceBeforeItIsAdmitted() async throws {
        try await start()
        let p = try await pairedPeer("Phone")
        guard case .welcome? = await p.hello() else { return XCTFail("no welcome") }
        try await service.removeDevice(p.identity.publicKey)
        let closed = await p.waitClosed(timeout: 2)
        XCTAssertTrue(closed)
    }

    /// Exactly one session-end line, `by device-removed`.
    func testRemovingALiveDeviceReportsItOnce() async throws {
        try await start()
        let reports = Reports(service.sessionEnds)
        let p = try await livePeer("Phone")
        try await service.removeDevice(p.identity.publicKey)
        let closed = await p.waitClosed(timeout: 2)
        XCTAssertTrue(closed)
        let seen = await poll { !reports.all.isEmpty }
        XCTAssertTrue(seen)
        try await Task.sleep(nanoseconds: 300_000_000)  // a negative: a second line would be a bug
        XCTAssertEqual(reports.all.count, 1)
        XCTAssertEqual(reports.all.first?.cause, .deviceRemoved)
        XCTAssertTrue(reports.all.first?.line.contains(", by device-removed, ") == true, "\(reports.all.first?.line ?? "")")
    }

    /// The write that unpairs fails: the session still ends (the person asked for it), the error comes back, and the device
    /// stays in the list (it is still paired in the store).
    func testRemoveStillEndsTheSessionWhenTheStoreFails() async throws {
        let secrets = FlakySecrets()
        try await start(secrets: secrets)
        let p = try await livePeer("Phone")
        secrets.failWrites = true
        do {
            try await service.removeDevice(p.identity.publicKey)
            XCTFail("the store error was swallowed")
        } catch {
            XCTAssertTrue(error is FlakySecrets.WriteFailed, "\(error)")
        }
        let closed = await p.waitClosed(timeout: 2)
        XCTAssertTrue(closed, "the session of a device the owner removed is still open")
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.name), ["Phone"])
    }

    /// A launch that waits for the library scan starts nothing for a device removed meanwhile.
    func testALaunchWaitingForTheScanStartsNothingForARemovedDevice() async throws {
        try await start()
        let p = try await livePeer("Phone")
        let gate = Gate()
        defer { gate.open() }
        await service.holdScan { await gate.hold() }
        p.send(.launch(titleID: fakeID))
        let entered = await gate.waitEntered()
        XCTAssertTrue(entered, "the launch never reached the scan")
        try await service.removeDevice(p.identity.publicKey)
        gate.open()
        try await Task.sleep(nanoseconds: 500_000_000)  // a negative: give the launch a real chance to (wrongly) go on
        XCTAssertNil(launcher.game, "a game was launched for a removed device")
    }

    func testRemoveUnknownDeviceIsNoError() async throws {
        try await start()
        let p = try await livePeer("Phone")
        try await service.removeDevice(Identity().publicKey)
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.name), ["Phone"])
        XCTAssertFalse(p.isClosed)
    }

    // MARK: folders

    func testSetLibraryRootsChangesTheList() async throws {
        let rootA = dir.appendingPathComponent("a"), rootB = dir.appendingPathComponent("b")
        try makeBundle(in: rootA, "One.app", titleID: "0000000000000001", name: "One")
        try makeBundle(in: rootB, "Two.app", titleID: "0000000000000002", name: "Two")
        try await start(extra: [], roots: [rootA])
        let first = await service.games().map(\.titleID)
        XCTAssertEqual(first, ["0000000000000001"])
        await service.setLibraryRoots([rootA, rootB])
        let both = await service.games().map(\.titleID)
        XCTAssertEqual(both, ["0000000000000001", "0000000000000002"], "the change shows at once, not after the scan's 2 s")
        await service.setLibraryRoots([rootB])
        let second = await service.games().map(\.titleID)
        XCTAssertEqual(second, ["0000000000000002"])
    }

    /// A game from a folder that was removed keeps running and stays listed with its state until it exits.
    func testARunningGameOfARemovedFolderStaysListed() async throws {
        let root = dir.appendingPathComponent("a")
        try makeBundle(in: root, "One.app", titleID: "0000000000000001", name: "One")
        try await start(extra: [], roots: [root])
        let p = try await livePeer("Phone")
        try await launchAndStream(p, "0000000000000001")
        await service.setLibraryRoots([])
        let listed = await service.games()
        XCTAssertEqual(listed, [GameEntry(titleID: "0000000000000001", name: "One", streamable: true, state: .running)])
        p.send(.listRequest)
        guard case let .list(sent)? = await p.next({ if case .list = $0 { true } else { false } }) else { return XCTFail("no list") }
        XCTAssertEqual(sent, listed, "a client sees the same list")
        await service.quitGame()
        let gone = await poll { launcher.game?.isFinished == true }
        XCTAssertTrue(gone)
        var left = await service.games()
        let end = Date().addingTimeInterval(3)
        while !left.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 20_000_000); left = await service.games() }
        XCTAssertEqual(left, [], "the exited game is still listed")
    }

    /// A change of folders while a scan reads the disk is not undone by the scan's result.
    func testAFolderChangeDuringAScanIsNotLost() async throws {
        let rootA = dir.appendingPathComponent("a"), rootB = dir.appendingPathComponent("b")
        try makeBundle(in: rootA, "One.app", titleID: "0000000000000001", name: "One")
        try makeBundle(in: rootB, "Two.app", titleID: "0000000000000002", name: "Two")
        try await start(extra: [], roots: [rootA])
        let gate = Gate()
        defer { gate.open() }
        await service.holdScan { await gate.hold() }
        let s = service!
        let pending = Task { await s.games() }
        let entered = await gate.waitEntered()
        XCTAssertTrue(entered)
        await service.setLibraryRoots([rootB])
        await service.holdScan(nil)
        gate.open()
        _ = await pending.value
        let now = await service.games().map(\.titleID)
        XCTAssertEqual(now, ["0000000000000002"], "the old scan came back after the change")
    }

    // MARK: quit

    func testHostQuitGame() async throws {
        try await start()
        let p = try await livePeer("Phone")
        try await launchAndStream(p)
        let game = try XCTUnwrap(launcher.game)
        await service.quitGame()
        let quit = await poll { game.received.contains(.quit) }
        XCTAssertTrue(quit, "the game was not asked to quit")
        let idle = await p.next { $0.gameState?.run == .idle }
        XCTAssertNotNil(idle)
        XCTAssertTrue(game.isFinished)
    }

    /// With no game the live client still gets the state, and nothing else happens.
    func testQuitWithoutAGameTellsTheClient() async throws {
        try await start()
        let p = try await livePeer("Phone")
        _ = await p.next { $0.gameState != nil }
        let n = p.messages.count
        await service.quitGame()
        let state = await p.next { $0.gameState?.run == .idle }
        XCTAssertNotNil(state)
        XCTAssertGreaterThan(p.messages.count, n)
    }

    /// A game that ignores the quit is terminated after the grace.
    func testHostQuitTerminatesAfterTheGrace() async throws {
        let clock = AdminClock()
        let detached = DetachedLauncher()
        try await start(launcher: detached, clock: { clock.now })
        let p = try await livePeer("Phone")
        p.send(.launch(titleID: fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running)
        await service.quitGame()
        let quit = await poll { detached.games.first?.received.contains(.quit) == true }
        XCTAssertTrue(quit)
        try await Task.sleep(nanoseconds: 400_000_000)  // a negative: no terminate inside the grace
        XCTAssertEqual(detached.terminations, 0)
        clock.advance(5.5)
        let terminated = await poll { detached.terminations == 1 }
        XCTAssertTrue(terminated, "terminate() was not called after the grace (\(detached.terminations))")
    }

    // MARK: pairing

    func testCancelPairing() async throws {
        try await start()
        let statuses = StatusCollector(service.status)
        let code = try await service.beginPairing()
        let shown = await statuses.wait { statuses.all.contains { if case .pairing = $0 { true } else { false } } }
        XCTAssertTrue(shown)
        await service.cancelPairing()
        let left = await statuses.wait { statuses.all.last == .idle }
        XCTAssertTrue(left, "\(statuses.all)")
        let p = peer("Phone")
        try p.connect(port: port)
        let result = try await p.pair(code: code)
        XCTAssertEqual(result, .expired)
    }

    func testNewCodeReplacesOld() async throws {
        try await start()
        let statuses = StatusCollector(service.status)
        let first = try await service.beginPairing()
        var second = try await service.beginPairing()
        while second == first { second = try await service.beginPairing() }  // 1 in a million
        let stale = peer("Phone")
        try stale.connect(port: port)
        let r1 = try await stale.pair(code: first)
        if case .ok = r1 { XCTFail("the old code paired") }
        let good = peer("Tablet")
        try good.connect(port: port)
        let r2 = try await good.pair(code: second)
        guard case .ok = r2 else { return XCTFail("the new code failed: \(r2)") }
        let seen = await statuses.wait {
            statuses.all.contains { if case let .pairing(code, _) = $0 { code == second } else { false } }
        }
        XCTAssertTrue(seen)
    }

    func testThePairingStatusCarriesTheWallClockEnd() async throws {
        try await start()
        let statuses = StatusCollector(service.status)
        let code = try await service.beginPairing()
        let shown = await statuses.wait { statuses.all.contains { if case .pairing = $0 { true } else { false } } }
        XCTAssertTrue(shown)
        guard case let .pairing(shownCode, until)? = statuses.all.last else { return XCTFail("\(statuses.all)") }
        XCTAssertEqual(shownCode, code)
        XCTAssertEqual(until.timeIntervalSinceNow, PairingLimits.lifetime, accuracy: 3)
    }

    // MARK: secret store

    /// `storeURL` is never read or written: it is in a folder that does not exist (nothing appears), then it holds another
    /// Host's file (the identity does not come from it, and the file is not changed).
    func testStoreOnSecrets() async throws {
        let secrets = MemorySecrets()
        try await start(secrets: secrets)
        let identity = service.discoveryID
        let p = try await pairedPeer("Phone")
        p.close()
        await service.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "something was created at storeURL's folder")
        try await start(secrets: secrets)
        XCTAssertEqual(service.discoveryID, identity, "another identity")
        let again = peer("Phone", like: p)
        try await again.open(port: port)
        XCTAssertTrue(again.sessionKnown, "the device had to pair again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        await service.stop()

        let file = dir.appendingPathComponent("host.json")
        let other = try PairingStore(fileURL: file)
        let before = try Data(contentsOf: file)
        try await start(secrets: secrets)
        XCTAssertEqual(service.discoveryID, identity, "the identity came from the file")
        XCTAssertNotEqual(service.discoveryID, other.identity.discoveryID)
        await service.stop()
        XCTAssertEqual(try Data(contentsOf: file), before, "the file was written")
    }

    // MARK: discovery

    func testDiscoveryIDMatchesTheKey() async throws {
        let one = try PairingStore(fileURL: dir.appendingPathComponent("one.json"))
        let two = try PairingStore(fileURL: dir.appendingPathComponent("two.json"))
        let id = Identity.discoveryID(publicKey: one.identity.publicKey)
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) }, id)
        XCTAssertEqual(id, one.identity.discoveryID)
        XCTAssertNotEqual(id, Identity.discoveryID(publicKey: two.identity.publicKey))

        let name = "nxPortal Test " + UUID().uuidString.prefix(8)
        try await start(name: name, advertise: true)
        XCTAssertEqual(service.discoveryID.count, 16)
        let first = service.discoveryID
        await service.stop()
        try await start(name: name, advertise: true)
        XCTAssertEqual(service.discoveryID, first, "the ID changed across a restart on the same store")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("host.json"))
        try await start(name: name + " 2", advertise: true)
        XCTAssertNotEqual(service.discoveryID, first, "another store, the same ID")

        let advertised = await Self.advertisedID(of: name + " 2")
        XCTAssertEqual(advertised, service.discoveryID, "the TXT record does not carry the ID")
    }

    /// The `id` the service named `name` advertises, read through a browser (5 s).
    private static func advertisedID(of name: String) async -> String? {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()  // guards value
            private var v: String?
            var value: String? { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
        }
        let box = Box()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ControlListener.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                guard case let .service(n, _, _, _) = r.endpoint, n == name,
                      case let .bonjour(txt) = r.metadata, let id = txt["id"] else { continue }
                box.value = id
            }
        }
        browser.start(queue: DispatchQueue(label: "nxportal.test.browser"))
        defer { browser.cancel() }
        let end = Date().addingTimeInterval(5)
        while box.value == nil, Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        return box.value
    }

    // MARK: launch reasons

    private func reason(after message: ControlMessage, from p: ScriptedPeer) async -> GameState? {
        p.send(message)
        return await p.next { $0.gameState?.reason != nil }?.gameState
    }

    func testLaunchReasons() async throws {
        let plain = GameApp(titleID: "PLAIN00000000000", name: "Plain", url: URL(fileURLWithPath: "/nonexistent/Plain.app"), streamable: false)
        try await start(extra: [fake, plain])
        let p = try await livePeer("Phone")
        let unknown = await reason(after: .launch(titleID: "NOPE000000000000"), from: p)
        XCTAssertEqual(unknown, GameState(titleID: "NOPE000000000000", run: .idle, reason: "not found"))
        let rebuild = await reason(after: .launch(titleID: plain.titleID), from: p)
        XCTAssertEqual(rebuild, GameState(titleID: plain.titleID, run: .idle, reason: "rebuild needed"))
    }

    /// `stop()` returns only once a game that ignores SIGTERM is dead: a Host that exits right after it leaves nothing running.
    func testStopWaitsForAGameThatIgnoresTermToDie() async throws {
        let pidFile = dir.appendingPathComponent("game.pid")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("stubborn.sh")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nwhile :; do sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        try await start(launcher: StubbornLauncher(script: script))
        let p = try await livePeer("Phone")
        p.send(.launch(titleID: fakeID))
        var pid: pid_t = 0
        let started = await poll(timeout: 5) {
            pid = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            return pid > 0
        }
        XCTAssertTrue(started, "the game never started")
        await service.stop()
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        XCTAssertFalse(alive, "stop() returned while the game still ran")
    }

    func testLaunchReasonLauncherThrows() async throws {
        try await start(launcher: ThrowingLauncher())
        let p = try await livePeer("Phone")
        let failed = await reason(after: .launch(titleID: fakeID), from: p)
        XCTAssertEqual(failed, GameState(titleID: fakeID, run: .idle, reason: "launch failed"))
    }

    func testLaunchReasonTapVersion() async throws {
        try await start(launcher: WrongVersionLauncher())
        let p = try await livePeer("Phone")
        let refused = await reason(after: .launch(titleID: fakeID), from: p)
        XCTAssertEqual(refused, GameState(titleID: fakeID, run: .idle,
                                          reason: "tap protocol \(ProtocolVersion.tap + 1), Host speaks \(ProtocolVersion.tap)"))
    }

    // MARK: launch environment

    func testGameEnvironmentArrivesAndCannotOverrideTheHostsOwn() async throws {
        try await start(environment: { id in
            ["NX_TEST_VALUE": "for \(id)", "DM_STREAM": "/elsewhere", "DM_LAUNCHER": "1"]
        })
        let p = try await livePeer("Phone")
        try await launchAndStream(p)
        let env = try XCTUnwrap(launcher.environments.first)
        XCTAssertEqual(env["NX_TEST_VALUE"], "for \(fakeID)")
        XCTAssertNil(env["DM_STREAM"], "a reserved variable was passed on")
        XCTAssertNil(env["DM_LAUNCHER"], "a reserved variable was passed on")
    }

    // MARK: bitrate

    private func configBitrates(_ game: FakeGame) -> [UInt32] {
        game.received.compactMap { if case let .config(_, _, _, bitrate) = $0 { bitrate } else { nil } }
    }

    /// A hello with no bitrate gets `HostConfig.defaultBitrate` (not `HostDefaults.bitrate`).
    func testBitrateFromConfig() async throws {
        try await start(defaultBitrate: 8_000_000)
        let p = try await livePeer("Phone")  // its hello carries no bitrate
        try await launchAndStream(p)
        let game = try XCTUnwrap(launcher.game)
        XCTAssertEqual(configBitrates(game).first, 8_000_000)
    }

    /// `maxBitrate` caps the default, and only when it is lower: a default under it is used as it is (so a default that is
    /// ignored is told from one that is clamped).
    func testMaxBitrateClampsTheDefault() async throws {
        try await start(defaultBitrate: 3_000_000, maxBitrate: 5_000_000)
        let a = try await pairedPeer("Phone")
        try await a.open(port: port)
        try await launchAndStream(a)
        XCTAssertEqual(configBitrates(try XCTUnwrap(launcher.game)).first, 3_000_000, "under the maximum: used as it is")

        try await start(defaultBitrate: 8_000_000, maxBitrate: 5_000_000)
        let b = try await pairedPeer("Tablet")
        try await b.open(port: port)
        try await launchAndStream(b)
        XCTAssertEqual(configBitrates(try XCTUnwrap(launcher.game)).first, 5_000_000, "over the maximum: clamped")
    }

    // MARK: stop

    private func assertStopped(_ call: () async throws -> Void, line: UInt = #line) async {
        do { try await call(); XCTFail("no error after stop()", line: line) } catch {
            XCTAssertEqual(error as? HostServiceError, .stopped, line: line)
        }
    }

    /// After `stop()` none of the calls starts, launches or publishes anything.
    func testNothingWorksAfterStop() async throws {
        let rootA = dir.appendingPathComponent("a"), rootB = dir.appendingPathComponent("b")
        try makeBundle(in: rootA, "One.app", titleID: "0000000000000001", name: "One")
        try makeBundle(in: rootB, "Two.app", titleID: "0000000000000002", name: "Two")
        try await start(extra: [], roots: [rootA])
        let p = try await livePeer("Phone")
        let statuses = StatusCollector(service.status)
        await service.stop()
        let finished = await statuses.wait { statuses.isFinished }
        XCTAssertTrue(finished)
        let seen = statuses.all.count

        await assertStopped { try await self.service.removeDevice(p.identity.publicKey) }
        await service.setLibraryRoots([rootB])
        let games = await service.games()
        XCTAssertEqual(games, [])
        await service.quitGame()
        await service.cancelPairing()
        await assertStopped { _ = try await self.service.beginPairing() }
        XCTAssertNil(launcher.game)
        XCTAssertEqual(statuses.all.count, seen, "a status was published after stop()")
        XCTAssertTrue(launcher.environments.isEmpty)
        // removeDevice did nothing: the device is still paired in the store.
        let stored = await service.devices()
        XCTAssertEqual(stored.map(\.name), ["Phone"])
    }

    /// `stop()` while `games()` waits for its scan: the answer is empty and the cache is not used to start anything.
    func testGamesAfterAStopDuringTheScanIsEmpty() async throws {
        let root = dir.appendingPathComponent("a")
        try makeBundle(in: root, "One.app", titleID: "0000000000000001", name: "One")
        try await start(extra: [], roots: [root])
        let gate = Gate()
        defer { gate.open() }
        await service.holdScan { await gate.hold() }
        let s = service!
        let pending = Task { await s.games() }
        let entered = await gate.waitEntered()
        XCTAssertTrue(entered)
        await service.stop()
        gate.open()
        let games = await pending.value
        XCTAssertEqual(games, [])
    }
}

/// What `sessionEnds` yielded.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()  // guards items
    private var items: [SessionEndReport] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<SessionEndReport>) {
        task = Task { [weak self] in for await r in stream { self?.lock.withLock { self?.items.append(r) } } }
    }
    deinit { task?.cancel() }
    var all: [SessionEndReport] { lock.withLock { items } }
}
#endif
