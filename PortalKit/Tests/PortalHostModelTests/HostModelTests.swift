#if os(macOS)
import XCTest
import Foundation
import Network
import PortalKit
import PortalClientCore
import PortalTestSupport
@testable import PortalHostCore
@testable import PortalHostModel

/// A recording announcer.
final class RecordingAnnouncer: PairingAnnouncing, @unchecked Sendable {
    private let lock = NSLock()  // guards log
    private var log: [String] = []
    func announce(code: String) async { lock.withLock { log.append("announce:" + code) } }
    func withdraw() async { lock.withLock { log.append("withdraw") } }
    var events: [String] { lock.withLock { log } }
    var codes: [String] { events.compactMap { $0.hasPrefix("announce:") ? String($0.dropFirst(9)) : nil } }
    var withdrawals: Int { events.filter { $0 == "withdraw" }.count }
}

/// Holds an awaiting call until `open()`.
final class Latch: @unchecked Sendable {
    private let release: AsyncStream<Void>, releaseOut: AsyncStream<Void>.Continuation
    private let lock = NSLock()  // guards didEnter
    private var didEnter = false
    init() { (release, releaseOut) = AsyncStream.makeStream(of: Void.self) }
    func hold() async {
        lock.withLock { didEnter = true }
        for await _ in release { return }
    }
    var entered: Bool { lock.withLock { didEnter } }
    func open() { releaseOut.yield(()) }
}

private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

/// A notification centre that never answers the permission question.
private struct SilentCentre: NotificationCentring {
    func requestPermission() async -> Bool { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }; return false }
    func post(id: String, title: String, body: String) async {}
    func remove(id: String) async {}
}

/// A clock the test moves: `wait()` returns at the next `tick()` (or when its task is cancelled).
final class TickClock: @unchecked Sendable {
    private let lock = NSLock()  // guards waiters
    private var waiters: [(id: Int, c: CheckedContinuation<Void, Never>)] = []
    private var next = 0
    func wait() async {
        let id = lock.withLock { next += 1; return next }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { c.resume(); return }
                lock.withLock { waiters.append((id, c)) }
            }
        } onCancel: {
            let mine = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                let m = waiters.filter { $0.id == id }.map(\.c); waiters.removeAll { $0.id == id }; return m }
            mine.forEach { $0.resume() }
        }
    }
    func tick() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in let a = waiters.map(\.c); waiters = []; return a }
        all.forEach { $0.resume() }
    }
    var waiting: Int { lock.withLock { waiters.count } }
}

/// A wall the test moves (the open menu's lapse is measured on it).
final class MenuClock: @unchecked Sendable {
    private let lock = NSLock()  // guards t
    private var t = Date(timeIntervalSinceReferenceDate: 5_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

/// The model's `onEvent`, collected.
@MainActor
final class EventLog {
    private(set) var events: [HostEvent] = []
    func attach(to model: HostModel) { model.onEvent = { [self] e in events.append(e) } }
    var statuses: [HostStatus] { events.compactMap { if case let .status(s) = $0 { s } else { nil } } }
    var failures: [String] { events.compactMap { if case let .failed(t) = $0 { t } else { nil } } }
    var sessionEnds: [String] { events.compactMap { if case let .sessionEnd(l) = $0 { l } else { nil } } }
}

/// The model's one injection point for services, seen from outside: every service it made, and how often two lived at once.
@MainActor
final class ServiceLog {
    private(set) var services: [HostService] = []
    private(set) var attempts = 0
    /// `optionsURL` of each config the model made, in order.
    private(set) var optionsURLs: [URL?] = []
    /// What each config's `savedChoice` answered for a made-up domain: the reader it carries is what a run reads preferences with.
    private(set) var savedChoices: [String?] = []
    /// Services that were still alive when the next one was asked for (the model's rule: none).
    private(set) var overlaps = 0
    var hold: (@Sendable () async -> Void)?
    weak var model: HostModel?

    func make(_ config: HostConfig) async throws -> HostService {
        attempts += 1
        optionsURLs.append(config.optionsURL)
        savedChoices.append(config.savedChoice("test.nxportal.model", "DM_FPS_TARGET"))
        if model?.liveServices ?? 0 != 0 { overlaps += 1 }
        for earlier in services {
            let stopped = await earlier.stopped
            let tapPath = await earlier.tapSocketPath
            if !stopped || FileManager.default.fileExists(atPath: tapPath) { overlaps += 1 }
        }
        let service = try HostService(config: config)
        services.append(service)
        if let hold { await service.holdStart(hold) }
        return service
    }
}

@MainActor
final class HostModelTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private var defaults: UserDefaults!
    private var suite = ""
    private var secrets = MemorySecrets()
    private var announcer = RecordingAnnouncer()
    private var launcher = FakeLauncher()
    private var log = ServiceLog()
    private var models: [HostModel] = []
    private var sessions: [ClientSession] = []
    private var folders: [URL] = []
    private var heldSockets: [Int32] = []
    private var latches: [Latch] = []
    private let ticks = TickClock()
    private let menuClock = MenuClock()

    override func setUp() async throws {
        suite = "nxp-model-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        secrets = MemorySecrets()
        announcer = RecordingAnnouncer()
        launcher = FakeLauncher()
        log = ServiceLog()
    }

    override func tearDown() async throws {
        for l in latches { l.open() }  // a held start or teardown would make the `stop()` below wait for ever
        for s in sessions { await s.close() }
        sessions = []
        for m in models { await m.stop() }
        models = []
        launcher.game?.stop()
        for fd in heldSockets { close(fd) }
        heldSockets = []
        for f in folders { try? FileManager.default.removeItem(at: f) }
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeLatch() -> Latch {
        let l = Latch()
        latches.append(l)
        return l
    }

    private var fake: GameApp { GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true) }

    private func makeModel(secrets custom: (any SecretStoring)? = nil, launcher customLauncher: (any GameLaunching)? = nil,
                           port: UInt16 = 0, retry: TimeInterval = 0.2,
                           extra: [GameApp]? = nil, suiteDefaults: UserDefaults? = nil, systemRoots: [URL] = [],
                           announcing: (any PairingAnnouncing)? = nil, optionsFile: URL? = nil,
                           savedChoice: (@Sendable (String, String) -> String?)? = nil,
                           environment: @escaping @Sendable (String) -> [String: String] = { _ in [:] }) -> HostModel {
        let log = log
        let model = HostModel(
            store: HostSettingsStore(defaults: suiteDefaults ?? defaults), secrets: custom ?? secrets, announcer: announcing ?? announcer,
            launcher: customLauncher ?? launcher, extraGames: extra ?? [fake], port: port, logDirectory: nil, retryInterval: retry,
            gameEnvironment: environment, optionsFile: optionsFile, savedChoice: savedChoice, systemRoots: systemRoots, power: NoPower(), advertise: false,
            menuTick: { [ticks] in await ticks.wait() }, menuNow: { [menuClock] in menuClock.now },
            makeService: { config in try await log.make(config) })
        log.model = model
        models.append(model)
        return model
    }

    /// The per-game choices are kept in the file the app gives (its own folder), and in memory only when it gives none: a run
    /// that must not touch the person's folder never does.
    func testTheServiceKeepsPerGameChoicesWhereTheAppSaysAndNowhereElseByDefault() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-model-options-\(UUID().uuidString)/options.json")
        let withFile = makeModel(optionsFile: file)
        await withFile.start()
        let without = makeModel()
        await without.start()
        XCTAssertEqual(log.optionsURLs, [file, nil])
    }

    /// The reader of an app's own saved choices is the one the model is given (an automated run gives one that returns nothing);
    /// only a model given none reads the real preferences.
    func testTheSavedChoiceReaderIsTheOneTheModelIsGiven() async throws {
        let given = makeModel(savedChoice: { _, _ in nil })
        await given.start()
        let custom = makeModel(savedChoice: { domain, env in "\(domain)/\(env)" })
        await custom.start()
        XCTAssertEqual(log.savedChoices, [nil, "test.nxportal.model/DM_FPS_TARGET"])
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await cond()
    }

    private struct NotReady: Error, CustomStringConvertible { let description: String }

    private func runningPort(_ model: HostModel) throws -> UInt16 {
        if case let .running(port) = model.phase { return port }
        throw NotReady(description: "not running: \(model.phase) \(model.message ?? "")")
    }

    /// A live status for `device` (the shown name) playing `game`, whatever its tag.
    private func isLive(_ s: HostStatus, _ device: String, _ game: String?) -> Bool {
        if case let .live(d, _, g) = s { return d == device && g == game }
        return false
    }

    private func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    private func session(_ identity: Identity = Identity(), name: String = "Test Client", bitrate: UInt32? = nil,
                         adaptiveRate: Bool = true) -> ClientSession {
        let s = ClientSession(identity: identity, name: name, kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: bitrate,
                              adaptiveRate: adaptiveRate)
        sessions.append(s)
        return s
    }

    /// Started, in the pairing window, and paired with a new session.
    private func pair(_ model: HostModel, _ s: ClientSession) async throws -> PairedPeer {
        await model.beginPairing()
        var code = ""
        let shown = await waitFor { if case let .pairing(c, _) = model.status { code = c; return true }; return false }
        if !shown { throw NotReady(description: "no pairing code in \(model.status)") }
        try await s.connect(to: endpoint(try runningPort(model)))
        return try await s.pair(code: code)
    }

    private func started(_ model: HostModel) async throws {
        await model.start()
        let up = await waitFor(3) { if case .running = model.phase { true } else { false } }
        if !up { throw NotReady(description: "not running: \(model.phase) \(model.message ?? "")") }
    }

    /// A TCP port something else is listening on (closed by `tearDown`, or by `release`).
    private func occupiedPort() throws -> (port: UInt16, fd: Int32) {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        heldSockets.append(fd)
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
        return (UInt16(bigEndian: addr.sin6_port), fd)
    }

    private func release(_ fd: Int32) {
        close(fd)
        heldSockets.removeAll { $0 == fd }
    }

    private func makeBundle(in root: URL, _ relative: String, titleID: String, name: String) throws {
        let contents = root.appendingPathComponent(relative).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["DMTitleID": titleID, "DMStream": true, "CFBundleName": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    // MARK: start and pairing

    func testStartRunsAndListsGames() async throws {
        let model = makeModel()
        XCTAssertEqual(model.phase, .stopped)
        await model.start()
        guard case let .running(port) = model.phase else { return XCTFail("phase \(model.phase)") }
        XCTAssertNotEqual(port, 0)
        let listed = await waitFor { model.games.map(\.titleID) == [fakeID] }
        XCTAssertTrue(listed, "games \(model.games)")
        XCTAssertNil(model.message)
    }

    func testPairingShowsCodeAndDevice() async throws {
        let model = makeModel()
        try await started(model)
        let before = Date()
        await model.beginPairing()
        var code = "", until = Date.distantPast
        let shown = await waitFor { if case let .pairing(c, u) = model.status { code = c; until = u; return true }; return false }
        XCTAssertTrue(shown, "status \(model.status)")
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber), code)
        XCTAssertEqual(announcer.codes, [code])
        // The window is the service's: shown as it is, the model decides nothing about it.
        XCTAssertGreaterThan(until, before.addingTimeInterval(100))
        XCTAssertLessThan(until, Date().addingTimeInterval(125))

        let client = session(name: "Living Room")
        try await client.connect(to: endpoint(try runningPort(model)))
        _ = try await client.pair(code: code)
        let paired = await waitFor { model.devices.map(\.name) == ["Living Room"] && model.status == .idle }
        XCTAssertTrue(paired, "devices \(model.devices) status \(model.status)")
        XCTAssertEqual(announcer.events, ["announce:" + code, "withdraw"])
    }

    func testCancelPairingWithdraws() async throws {
        let model = makeModel()
        try await started(model)
        await model.beginPairing()
        let shown = await waitFor { if case .pairing = model.status { true } else { false } }
        XCTAssertTrue(shown)
        await model.cancelPairing()
        let left = await waitFor { model.status == .idle }
        XCTAssertTrue(left, "status \(model.status)")
        XCTAssertEqual(announcer.withdrawals, 1)
        XCTAssertEqual(announcer.codes.count, 1)
    }

    func testSecondBeginPairingAnnouncesNewCode() async throws {
        let model = makeModel()
        try await started(model)
        await model.beginPairing()
        let first = await waitFor { announcer.codes.count == 1 }
        XCTAssertTrue(first)
        var firstCode = ""
        if case let .pairing(c, _) = model.status { firstCode = c }
        var second = firstCode
        for _ in 0..<5 where second == firstCode {  // a new code is random: the odd repeat is not the model's fault
            await model.beginPairing()
            let announced = await waitFor { announcer.codes.last != second }
            XCTAssertTrue(announced)
            second = announcer.codes.last ?? second
        }
        XCTAssertNotEqual(second, firstCode)
        XCTAssertEqual(Set(announcer.codes).count, announcer.codes.count, "a code was announced twice: \(announcer.codes)")
        let stale = session()
        try await stale.connect(to: endpoint(try runningPort(model)))
        do {
            _ = try await stale.pair(code: firstCode)
            XCTFail("the replaced code still pairs")
        } catch {
            guard case .pairing? = error as? ClientError else { return XCTFail("\(error)") }
        }
    }

    func testBeginPairingWhileNotRunningOnlySetsAMessage() async throws {
        let model = makeModel()
        await model.beginPairing()
        XCTAssertEqual(model.message, HostMessages.notRunning)
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(announcer.events, [])
        XCTAssertEqual(log.attempts, 0, "a service was made")
    }

    // MARK: play, devices

    func testStatusFollowsPlay() async throws {
        let model = makeModel()
        try await started(model)
        let s = session(name: "Phone")
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let live = await waitFor { isLive(model.status, "Phone", "Fake Game") }
        XCTAssertTrue(live, "status \(model.status)")
        await s.close()
        let paused = await waitFor { model.status == .paused(game: "Fake Game") }
        XCTAssertTrue(paused, "status \(model.status)")
        await model.quitGame()
        let idle = await waitFor { model.status == .idle && model.games.map(\.state) == [.idle] }
        XCTAssertTrue(idle, "status \(model.status) games \(model.games)")
    }

    func testRemoveDevice() async throws {
        let model = makeModel()
        try await started(model)
        let s = session(name: "Phone")
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let live = await waitFor { isLive(model.status, "Phone", "Fake Game") }
        XCTAssertTrue(live, "status \(model.status)")
        let device = try XCTUnwrap(model.devices.first)
        XCTAssertTrue(device.live)
        await model.remove(device)
        XCTAssertEqual(model.devices, [])
        let paused = await waitFor { model.status == .paused(game: "Fake Game") }
        XCTAssertTrue(paused, "status \(model.status)")
        let ended = await waitFor { await s.end != nil }
        XCTAssertTrue(ended, "the device's session did not end")
        XCTAssertNil(model.message)
    }

    func testRemoveWhenTheStoreCannotWriteKeepsTheDeviceAndEndsItsSession() async throws {
        let flaky = FlakySecrets()
        let model = makeModel(secrets: flaky)
        try await started(model)
        let s = session(name: "Phone")
        let host = try await pair(model, s)
        try await s.open(host: host)
        let live = await waitFor { isLive(model.status, "Phone", nil) }
        XCTAssertTrue(live, "status \(model.status)")
        let device = try XCTUnwrap(model.devices.first)
        flaky.failWrites = true
        await model.remove(device)
        XCTAssertEqual(model.message, HostMessages.couldNotRemove("Phone"))
        XCTAssertEqual(model.devices.map(\.name), ["Phone"], "the device is still paired in the store")
        let left = await waitFor { model.status == .idle && model.devices.map(\.live) == [false] }
        XCTAssertTrue(left, "status \(model.status) devices \(model.devices)")
        let ended = await waitFor { await s.end != nil }
        XCTAssertTrue(ended, "the device's session did not end")
    }

    // MARK: device names -> .claude/host.md § model

    // MARK: the menu's second line, the preparing tag, the icons

    func testTheSentencesOfTheMenuRestyle() {
        XCTAssertEqual(HostMessages.statusDetail(device: "Test Mac", fps: 60, bps: 48_000_000), "Test Mac \u{00B7} 60 fps \u{00B7} 48 Mbit/s")
        XCTAssertEqual(HostMessages.statusDetail(device: "Test iPad", fps: 30, bps: 7_500_000), "Test iPad \u{00B7} 30 fps \u{00B7} 7.5 Mbit/s")
        XCTAssertEqual(HostMessages.statusDetail(device: "Test iPad", fps: 60, bps: 400_000), "Test iPad \u{00B7} 60 fps \u{00B7} 0.4 Mbit/s")
        XCTAssertEqual(HostMessages.statusDetail(device: "Test iPad", fps: nil, bps: 24_000_000), "Test iPad \u{00B7} 24 Mbit/s")
        XCTAssertEqual(HostMessages.preparingGame("Fake Game", for: "Test iPad"), "Preparing Fake Game for Test iPad")
        XCTAssertEqual(HostMessages.preparingTag(percent: 36), "preparing 36 %")
        XCTAssertEqual(HostMessages.preparingTag(of: Preparing(phase: 1, done: 360, total: 1000)), "preparing 36 %")
        XCTAssertEqual(HostMessages.preparingTag(of: Preparing(phase: 1, done: 5000, total: 1000)), "preparing 100 %", "never past 100")
        XCTAssertEqual(HostMessages.preparingTag(of: .waiting), "preparing", "no count yet: no number")
        XCTAssertEqual(HostMessages.preparingTag(of: Preparing(phase: 1, done: 3, total: 8)), "preparing 38 %", "the device's rule: rounded")
        XCTAssertEqual(HostMessages.preparingTag(of: Preparing(phase: 1, done: 9_990, total: 10_000)), "preparing 99 %", "100 only when done")
    }

    func testTheCodesTimeBarRunsDownAndStaysInRange() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(HostMessages.codeTimeLeft(until: now.addingTimeInterval(120), now: now), 1)
        XCTAssertEqual(HostMessages.codeTimeLeft(until: now.addingTimeInterval(30), now: now), 0.25)
        XCTAssertEqual(HostMessages.codeTimeLeft(until: now.addingTimeInterval(-5), now: now), 0, "past the end: empty")
        XCTAssertEqual(HostMessages.codeTimeLeft(until: now.addingTimeInterval(500), now: now), 1, "never past full")
    }

    /// The frame rate is what the game delivers, not the device's cap: a 30 fps game to a device that allows 60 reads 30.
    func testTheSecondStatusLineHasTheMeasuredFrameRateAndTheCurrentRate() async throws {
        let model = makeModel(launcher: FakeLauncher(fps: 30))
        try await started(model)
        XCTAssertNil(model.statusDetail, "no session")
        let s = session(name: "Test iPad", bitrate: 48_000_000, adaptiveRate: false)
        let host = try await pair(model, s)
        try await s.open(host: host)
        let live = await waitFor { isLive(model.status, "Test iPad", nil) }
        XCTAssertTrue(live, "status \(model.status)")
        await model.refresh()
        XCTAssertEqual(model.statusDetail, "Test iPad \u{00B7} 48 Mbit/s", "no game yet: nothing measured, so no frame rate, never the cap")
        try await s.launch(titleID: fakeID)
        let measured = await waitFor(8) { await model.refresh(); return model.statusDetail == "Test iPad \u{00B7} 30 fps \u{00B7} 48 Mbit/s" }
        XCTAssertTrue(measured, "the line: \(String(describing: model.statusDetail))")
        await s.close()
        let gone = await waitFor { await model.refresh(); return model.statusDetail == nil }
        XCTAssertTrue(gone, "the line leaves with the session: \(String(describing: model.statusDetail))")
    }

    func testTheMenuReadsOnlyWhileItIsOpen() async throws {
        let model = makeModel()
        try await started(model)
        XCTAssertEqual(model.menuRefreshes, 0)
        ticks.tick(); ticks.tick()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.menuRefreshes, 0, "closed: nothing runs, however long it waits")
        XCTAssertEqual(ticks.waiting, 0, "closed: nothing is waiting on the clock")
        model.menuOpened()
        model.menuOpened()  // a second open while open: still one loop
        var up = await waitFor { model.menuRefreshes == 1 && ticks.waiting == 1 }
        XCTAssertTrue(up, "opening reads once and waits for one tick: \(model.menuRefreshes), waiting \(ticks.waiting)")
        ticks.tick()
        up = await waitFor { model.menuRefreshes == 2 && ticks.waiting == 1 }
        XCTAssertTrue(up, "one tick, one read, even after a double open: \(model.menuRefreshes)")
        model.menuClosed()
        model.menuClosed()  // closing twice is harmless
        ticks.tick()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.menuRefreshes, 2, "closed: the tick reads nothing")
        XCTAssertEqual(ticks.waiting, 0)
        model.menuOpened()
        up = await waitFor { model.menuRefreshes == 3 && ticks.waiting == 1 }
        XCTAssertTrue(up, "a second open works: \(model.menuRefreshes)")
        ticks.tick()
        up = await waitFor { model.menuRefreshes == 4 }
        XCTAssertTrue(up)
        model.menuClosed()
    }

    /// A close the view never reported: the loop ends by itself 10 s after the last "still open".
    func testAnOpenMenuNobodyReaffirmsEndsByItself() async throws {
        let model = makeModel()
        try await started(model)
        model.menuOpened()
        var up = await waitFor { model.menuRefreshes == 1 && ticks.waiting == 1 }
        XCTAssertTrue(up)
        for n in 2...4 {  // the view draws each refresh and says so: the loop outlives the lapse
            menuClock.advance(4)
            model.menuStillOpen()
            ticks.tick()
            up = await waitFor { model.menuRefreshes == n && ticks.waiting == 1 }
            XCTAssertTrue(up, "re-affirmed: read \(n), got \(model.menuRefreshes)")
        }
        menuClock.advance(10.5)  // nobody re-affirms and nobody closes
        ticks.tick()
        let ended = await waitFor { ticks.waiting == 0 }
        XCTAssertTrue(ended, "the loop ended")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.menuRefreshes, 4, "and read nothing more")
        ticks.tick()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.menuRefreshes, 4)
        model.menuClosed()  // a late close is harmless
        model.menuOpened()  // and the next open starts afresh
        up = await waitFor { model.menuRefreshes == 5 && ticks.waiting == 1 }
        XCTAssertTrue(up, "reopened: \(model.menuRefreshes)")
        model.menuClosed()
    }

    func testAReaffirmedMenuJustUnderTheLapseKeepsReading() async throws {
        let model = makeModel()
        try await started(model)
        model.menuOpened()
        var up = await waitFor { model.menuRefreshes == 1 && ticks.waiting == 1 }
        XCTAssertTrue(up)
        menuClock.advance(9.5)  // under 10 s since the open
        ticks.tick()
        up = await waitFor { model.menuRefreshes == 2 && ticks.waiting == 1 }
        XCTAssertTrue(up, "9.5 s is within the lapse: \(model.menuRefreshes)")
        model.menuStillOpen()  // a still-open for a menu that is not open starts nothing
        model.menuClosed()
        model.menuStillOpen()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ticks.waiting, 0)
    }

    func testAnIconIsFetchedAgainOnlyWhenItsHashChanged() async throws {
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-icons-" + UUID().uuidString)
        folders.append(lib)
        let app = try FakeArt.makeApp(in: lib, titleID: "ICON000000000001", name: "Iconic", paint: .flat(0x3366FF), side: 256)
        let model = makeModel(extra: [GameApp(titleID: "ICON000000000001", name: "Iconic", url: app, streamable: true)])
        try await started(model)
        let there = await waitFor { await model.refresh(); return model.gameIcon(titleID: "ICON000000000001") != nil }
        XCTAssertTrue(there)
        let before = model.iconFetches
        for _ in 0..<5 { await model.refresh() }
        XCTAssertEqual(model.iconFetches, before, "the same hash: no fetch")
        let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        try FakeArt.write(FakeArt.image(.flat(0xFF3300), side: 1024), to: icon)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: icon.path)
        let old = model.gameIcon(titleID: "ICON000000000001")
        let changed = await waitFor { await model.refresh(); return model.gameIcon(titleID: "ICON000000000001") != old }
        XCTAssertTrue(changed, "a new hash: fetched again")
    }

    func testAPreparingGameHasItsNumbersAndItsTag() async throws {
        let preparer = FakeLauncher(prepareSteps: [FakeGame.PrepareStep(phase: 1, done: 360, total: 1000)], stall: 30)
        let model = makeModel(launcher: preparer)
        try await started(model)
        XCTAssertNil(model.preparing(titleID: fakeID))
        let s = session(name: "Test iPad")
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let there = await waitFor { await model.refresh(); return model.preparing(titleID: fakeID)?.done == 360 }
        XCTAssertTrue(there, "preparing \(String(describing: model.preparing(titleID: fakeID)))")
        XCTAssertEqual(model.preparing(titleID: fakeID), Preparing(phase: 1, done: 360, total: 1000))
        XCTAssertEqual(model.preparingTag(titleID: fakeID), "preparing 36 %")
        XCTAssertNil(model.preparing(titleID: "OTHER0000000000"), "only the game that prepares")
        XCTAssertEqual(model.preparingHeadline, "Preparing Fake Game for Test iPad", "the headline says so while the game prepares")
    }

    /// Once the preparation ends the headline is the game's: no "Preparing" line is left (the app then reads "Playing …").
    func testTheHeadlineIsPlayingOnceThePreparationEnds() async throws {
        let preparer = FakeLauncher(prepareSteps: [FakeGame.PrepareStep(phase: 1, done: 360, total: 1000)], stall: 1)
        let model = makeModel(launcher: preparer)
        try await started(model)
        let s = session(name: "Test iPad")
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let preparing = await waitFor { await model.refresh(); return model.preparingHeadline != nil }
        XCTAssertTrue(preparing, "it prepares first")
        let over = await waitFor(15) { await model.refresh(); return model.preparingHeadline == nil && model.preparing(titleID: fakeID) == nil }
        XCTAssertTrue(over, "the preparation ended: \(String(describing: model.preparingHeadline))")
        guard case let .live(device, _, game) = model.status else { return XCTFail("status \(model.status)") }
        XCTAssertEqual(device, "Test iPad")
        XCTAssertEqual(game, "Fake Game", "the status names the game, so the app's line is the playing one")
    }

    func testAGameWithAnIconHasItAndOneWithoutHasNone() async throws {
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-icons-" + UUID().uuidString)
        folders.append(lib)
        let withIcon = try FakeArt.makeApp(in: lib, titleID: "ICON000000000001", name: "Iconic", paint: .flat(0x3366FF), side: 256)
        let without = try FakeArt.makeApp(in: lib, titleID: "ICON000000000002", name: "Plain", paint: nil)
        let model = makeModel(extra: [
            GameApp(titleID: "ICON000000000001", name: "Iconic", url: withIcon, streamable: true),
            GameApp(titleID: "ICON000000000002", name: "Plain", url: without, streamable: true)])
        try await started(model)
        let listed = await waitFor { await model.refresh(); return model.gameIcon(titleID: "ICON000000000001") != nil }
        XCTAssertTrue(listed, "games \(model.games)")
        XCTAssertNil(model.gameIcon(titleID: "ICON000000000002"))
        XCTAssertNil(model.gameIcon(titleID: "UNKNOWN"))
    }

    /// Two devices that call themselves alike are numbered; a rename shows at once, in the list and in the status.
    func testDevicesAreNumberedAndARenameShowsInTheListAndTheStatus() async throws {
        let model = makeModel()
        try await started(model)
        let a = session(name: "iPad"), b = session(name: "iPad")
        let hostA = try await pair(model, a)
        _ = try await pair(model, b)
        await model.refresh()
        XCTAssertEqual(model.devices.map(\.shownName), ["iPad", "iPad 2"])
        try await a.open(host: hostA)
        let live = await waitFor { isLive(model.status, "iPad", nil) }
        XCTAssertTrue(live, "status \(model.status)")
        let first = try XCTUnwrap(model.devices.first { $0.shownName == "iPad" })
        await model.rename(first, to: "Den iPad")
        XCTAssertNil(model.message)
        XCTAssertEqual(model.devices.map(\.shownName), ["Den iPad", "iPad"], "sorted by shown name, and the other is no longer numbered")
        let renamed = await waitFor { isLive(model.status, "Den iPad", nil) }
        XCTAssertTrue(renamed, "the status line follows the rename: \(model.status)")
        await model.rename(model.devices.first { $0.shownName == "Den iPad" }!, to: nil)
        XCTAssertEqual(model.devices.map(\.shownName), ["iPad", "iPad 2"])
    }

    /// The rename field starts from the Host's own name, else the device's own name (never the computed number), and saving it
    /// unchanged sets no alias.
    func testTheRenameDraftIsNeverTheComputedNumberAndAnUnchangedSaveSetsNoAlias() async throws {
        let model = makeModel()
        try await started(model)
        _ = try await pair(model, session(name: "iPad"))
        _ = try await pair(model, session(name: "iPad"))
        await model.refresh()
        let second = try XCTUnwrap(model.devices.first { $0.shownName == "iPad 2" })
        XCTAssertEqual(model.renameDraft(for: second), "iPad", "the device's own name")
        await model.rename(second, to: model.renameDraft(for: second))
        await model.refresh()
        XCTAssertEqual(model.devices.map(\.shownName), ["iPad", "iPad 2"], "no alias was set: the number still follows")
        XCTAssertNil(model.devices.first { $0.id == second.id }?.alias)
        await model.rename(second, to: "Den iPad")
        let named = try XCTUnwrap(model.devices.first { $0.id == second.id })
        XCTAssertEqual(named.alias, "Den iPad")
        XCTAssertEqual(model.renameDraft(for: named), "Den iPad", "the alias when there is one")
    }

    func testRemoveNamesTheDeviceByItsShownNameWhenTheStoreFails() async throws {
        let flaky = FlakySecrets()
        let model = makeModel(secrets: flaky)
        try await started(model)
        let s = session(name: "iPad")
        _ = try await pair(model, s)
        await model.refresh()
        let device = try XCTUnwrap(model.devices.first)
        await model.rename(device, to: "Den iPad")
        flaky.failWrites = true
        await model.remove(try XCTUnwrap(model.devices.first))
        XCTAssertEqual(model.message, HostMessages.couldNotRemove("Den iPad"))
        await model.rename(try XCTUnwrap(model.devices.first), to: "Other")
        XCTAssertEqual(model.message, HostMessages.couldNotRename("Den iPad"))
        XCTAssertEqual(model.devices.map(\.shownName), ["Den iPad"], "nothing was saved")
    }

    func testStopEndsTheGame() async throws {
        let model = makeModel()
        try await started(model)
        let s = session()
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let connected = await waitFor { launcher.game?.received.isEmpty == false }
        XCTAssertTrue(connected, "the game never connected")
        let game = try XCTUnwrap(launcher.game)
        await model.stop()
        // The fake game's reader thread finishes a moment after `terminate()`; the service itself is down when `stop()` returns.
        let ended = await waitFor(5) { game.isFinished }
        XCTAssertTrue(ended, "the game is still running")
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.status, .idle)
        await model.stop()  // twice: returns
        XCTAssertEqual(model.phase, .stopped)
    }

    // MARK: settings that act

    func testFoldersPersistAndApply() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-m-" + UUID().uuidString)
        folders.append(folder)
        try makeBundle(in: folder, "Game.app", titleID: "BUNDLE0000000001", name: "Bundle Game")
        let model = makeModel()
        try await started(model)
        XCTAssertEqual(model.games.map(\.titleID), [fakeID])
        await model.addFolder(folder)
        await model.addFolder(folder)
        XCTAssertEqual(model.settings.folders.map(\.path), [folder.standardizedFileURL.path], "added twice, kept once")
        let added = await waitFor { Set(model.games.map(\.titleID)) == [fakeID, "BUNDLE0000000001"] }
        XCTAssertTrue(added, "games \(model.games)")

        let second = makeModel()
        XCTAssertEqual(second.settings.folders.map(\.path), [folder.standardizedFileURL.path], "a new model on the same defaults")

        await model.removeFolder(folder)
        XCTAssertEqual(model.settings.folders, [])
        let gone = await waitFor { model.games.map(\.titleID) == [fakeID] }
        XCTAssertTrue(gone, "games \(model.games)")
        XCTAssertEqual(makeModel().settings.folders, [])
    }

    func testAMissingFolderIsRefusedWithAMessage() async throws {
        let model = makeModel()
        try await started(model)
        await model.addFolder(FileManager.default.temporaryDirectory.appendingPathComponent("nxp-m-none-" + UUID().uuidString))
        XCTAssertEqual(model.message, HostMessages.folderMissing)
        XCTAssertEqual(model.settings.folders, [])
    }

    func testLibraryRootsAreTheApplicationFoldersThenTheOnesTheUserAdded() async throws {
        let extra = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-m-" + UUID().uuidString)
        folders.append(extra)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let system = [URL(fileURLWithPath: "/Applications"), home]
        let roots = HostModel.libraryRoots(system: system, folders: [extra, URL(fileURLWithPath: "/Applications"), extra])
        XCTAssertEqual(roots.map(\.path), ["/Applications", home.standardizedFileURL.path, extra.standardizedFileURL.path])
        let model = HostModel(store: HostSettingsStore(defaults: defaults), secrets: secrets, announcer: announcer, logDirectory: nil)
        XCTAssertEqual(model.libraryRoots.prefix(2).map(\.path), ["/Applications", home.standardizedFileURL.path])
    }

    func testRenameRestartsWithNewName() async throws {
        let model = makeModel()
        try await started(model)
        let id = Identity()
        let s = session(id, name: "Phone")
        let host = try await pair(model, s)
        await model.rename("Test Host B")
        XCTAssertEqual(model.activeName, "Test Host B")
        let advertised = await log.services.last?.config.name
        XCTAssertEqual(advertised, "Test Host B", "the name the service itself was configured with")
        let first = await log.services.first?.config.name
        XCTAssertNotEqual(first, "Test Host B")
        XCTAssertEqual(model.settings.name, "Test Host B")
        guard case .running = model.phase else { return XCTFail("phase \(model.phase)") }
        XCTAssertEqual(log.services.count, 2)
        XCTAssertEqual(log.overlaps, 0)
        XCTAssertEqual(makeModel().settings.name, "Test Host B")

        let again = session(id, name: "Phone")
        try await again.connect(to: endpoint(try runningPort(model)))
        try await again.open(host: host)  // still paired: no code
        let games = try await again.list()
        XCTAssertEqual(games.map(\.titleID), [fakeID])
        XCTAssertEqual(model.devices.map(\.name), ["Phone"])
    }

    func testTheMaximumBitrateReachesTheHost() async throws {
        HostSettingsStore(defaults: defaults).save(HostSettings(maxBitrate: 40_000_000))
        let model = makeModel()
        try await started(model)
        let s = session(bitrate: 150_000_000, adaptiveRate: false)
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        _ = await waitFor { launcher.game?.received.contains { if case .config = $0 { true } else { false } } ?? false }
        var bitrate: UInt32?
        for m in launcher.game?.received ?? [] { if case let .config(_, _, _, b) = m { bitrate = b } }
        XCTAssertEqual(bitrate, 40_000_000)
    }

    func testTheGameEnvironmentReachesTheLauncher() async throws {
        let model = makeModel(environment: { id in id == "FAKE000000000000" ? ["NXP_TEST": "1"] : [:] })
        try await started(model)
        let s = session()
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let launched = await waitFor { !launcher.environments.isEmpty }
        XCTAssertTrue(launched)
        XCTAssertEqual(launcher.environments.first?["NXP_TEST"], "1")
    }

    // MARK: the person's last word

    func testAStopDuringARenameWins() async throws {
        let model = makeModel()
        try await started(model)
        let renaming = Task { await model.rename("Test Host B") }
        await Task.yield()  // the rename is now stopping the service
        await model.stop()
        await renaming.value
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.settings.name, "Test Host B", "the new name is saved all the same")
        XCTAssertEqual(log.services.count, 1, "a service was made after the stop")
        XCTAssertEqual(model.liveServices, 0)
    }

    func testStopStartStopWithoutAwaitingEndsStopped() async throws {
        let model = makeModel()
        try await started(model)
        let a = Task { await model.stop() }
        let b = Task { await model.start() }
        let c = Task { await model.stop() }
        await a.value; await b.value; await c.value
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.liveServices, 0)
        XCTAssertEqual(log.services.count, 1)
    }

    func testStartStopStartWithoutAwaitingEndsRunningWithOneService() async throws {
        let model = makeModel()
        let a = Task { await model.start() }
        let b = Task { await model.stop() }
        let c = Task { await model.start() }
        await a.value; await b.value; await c.value
        let up = await waitFor { if case .running = model.phase { true } else { false } }
        XCTAssertTrue(up, "phase \(model.phase)")
        XCTAssertEqual(model.liveServices, 1)
        XCTAssertEqual(log.overlaps, 0)
        var alive = 0
        for svc in log.services { if await !svc.stopped { alive += 1 } }
        XCTAssertEqual(alive, 1, "exactly one service is up")
    }

    func testStartTwiceMakesOneService() async throws {
        let model = makeModel()
        let a = Task { await model.start() }
        let b = Task { await model.start() }
        await a.value; await b.value
        try await started(model)
        await model.start()
        XCTAssertEqual(log.services.count, 1)
        XCTAssertEqual(model.liveServices, 1)
    }

    /// `start()` during a retry wait returns at once and neither makes a service nor hastens the retry.
    func testStartDuringARetryWaitDoesNothing() async throws {
        let (taken, _) = try occupiedPort()
        let model = makeModel(port: taken, retry: 30)
        await model.start()
        guard case .failed = model.phase else { return XCTFail("phase \(model.phase)") }
        await model.start()
        XCTAssertEqual(log.attempts, 1)
        guard case .failed = model.phase else { return XCTFail("phase \(model.phase)") }
    }

    // MARK: rename and a running game

    func testRenameEndsALiveGameAndRestartsUnderTheNewNameWithoutAFailure() async throws {
        let model = makeModel()
        try await started(model)
        XCTAssertFalse(model.gameIsActive)
        let s = session(name: "Phone")
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let active = await waitFor { model.gameIsActive }
        XCTAssertTrue(active, "status \(model.status) games \(model.games)")
        let connected = await waitFor { launcher.game?.received.isEmpty == false }
        XCTAssertTrue(connected)
        let game = try XCTUnwrap(launcher.game)
        await model.rename("Test Host B")
        let ended = await waitFor(5) { game.isFinished }
        XCTAssertTrue(ended, "the game is still running")
        guard case .running = model.phase else { return XCTFail("phase \(model.phase)") }
        let advertised = await log.services.last?.config.name
        XCTAssertEqual(advertised, "Test Host B")
        XCTAssertEqual(log.services.count, 2)
        XCTAssertNil(model.message, "a rename is no failure")
        let idle = await waitFor { !model.gameIsActive && model.status == .idle }
        XCTAssertTrue(idle, "status \(model.status)")
    }

    // MARK: stale readings

    /// A game whose end waits for the test.
    private struct SlowEndGame: RunningGame {
        let inner: any RunningGame
        let latch: Latch
        func terminate() async { await latch.hold(); await inner.terminate() }
        func waitForExit() async -> Int32 { await inner.waitForExit() }
    }

    private final class SlowEndLauncher: GameLaunching, @unchecked Sendable {
        let inner = FakeLauncher()
        let latch: Latch
        init(latch: Latch) { self.latch = latch }
        func launch(titleID: String, socketPath: String) async throws -> any RunningGame {
            SlowEndGame(inner: try await inner.launch(titleID: titleID, socketPath: socketPath), latch: latch)
        }
    }

    /// A refresh that is waiting in the service when the service fails must not fill the lists again.
    func testARefreshSuspendedInTheServiceWhenItFailsLeavesBothListsEmpty() async throws {
        let teardown = makeLatch(), scan = makeLatch()
        let slow = SlowEndLauncher(latch: teardown)
        let model = makeModel(launcher: slow, retry: 30)
        try await started(model)
        let s = session(name: "Phone")
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        let ready = await waitFor { slow.inner.game?.received.isEmpty == false && model.devices.map(\.name) == ["Phone"] }
        XCTAssertTrue(ready, "devices \(model.devices)")
        let svc = log.services[0]
        await svc.holdScan { await scan.hold() }
        await svc.setLibraryRoots([])  // drops the cached scan: the next games() waits in the hold
        let refreshing = Task { await model.refresh() }
        let waiting = await waitFor { scan.entered }
        XCTAssertTrue(waiting, "the refresh never reached the service's scan")
        await svc.control.failForTest(NWError.posix(.ENETDOWN))
        let tearing = await waitFor { teardown.entered }  // the model has shown the failure; the service is still going down
        XCTAssertTrue(tearing)
        guard case .failed = model.phase else { return XCTFail("phase \(model.phase)") }
        scan.open()
        await refreshing.value
        XCTAssertEqual(model.devices, [], "a stale reading refilled the devices")
        XCTAssertEqual(model.games, [], "a stale reading refilled the games")
        teardown.open()
    }

    /// A `.failed` that reaches the model while `stop()` runs is not shown.
    func testAFailureArrivingDuringStopIsNotShown() async throws {
        let scan = makeLatch()
        let model = makeModel(retry: 30)
        try await started(model)
        let svc = log.services[0]
        await svc.holdScan { await scan.hold() }
        await svc.setLibraryRoots([])
        await model.beginPairing()  // the status change makes the model read the games: it waits in the scan
        let waiting = await waitFor { scan.entered }
        XCTAssertTrue(waiting, "the model never reached the service's scan")
        await svc.control.failForTest(NWError.posix(.ENETDOWN))  // `.failed` is queued behind the busy model
        let stopping = Task { await model.stop() }
        let down = await waitFor { await svc.stopped }
        XCTAssertTrue(down)
        scan.open()
        await stopping.value
        XCTAssertEqual(model.failuresShown, 0, "a failure was shown during a stop")
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.liveServices, 0)
    }


    // MARK: events for the app's log

    func testEventsCarryListeningStatusAndTheSessionEndLine() async throws {
        let model = makeModel()
        let events = EventLog()
        events.attach(to: model)
        try await started(model)
        guard case let .running(port) = model.phase else { return XCTFail("phase \(model.phase)") }
        XCTAssertTrue(events.events.contains(.listening(port: port)), "\(events.events)")
        let phone = Identity()
        let s = session(phone, name: "Phone")
        let host = try await pair(model, s)
        try await s.open(host: host)
        try await s.launch(titleID: fakeID)
        _ = await waitFor { isLive(model.status, "Phone", "Fake Game") }
        await s.close()
        let paused = await waitFor { events.statuses.contains(.paused(game: "Fake Game")) }
        XCTAssertTrue(paused, "\(events.statuses)")
        let ended = await waitFor { events.sessionEnds.count == 1 }
        XCTAssertTrue(ended, "\(events.events)")
        XCTAssertTrue(events.sessionEnds[0].hasPrefix("session end: \(Identity.tag(publicKey: phone.publicKey)) after "), events.sessionEnds[0])
        XCTAssertFalse(events.sessionEnds[0].contains("Phone"), "a session's log line carries no name")
        XCTAssertFalse(events.statuses.map { HostEventLine.text(.status($0), showCode: false) }.contains { $0.contains("Phone") },
                       "no status line carries a name")
        XCTAssertTrue(events.sessionEnds[0].contains("by client-closed"), events.sessionEnds[0])
        XCTAssertTrue(events.statuses.contains { if case .pairing = $0 { true } else { false } })
        XCTAssertTrue(events.statuses.contains { isLive($0, "Phone", "Fake Game") })
    }

    /// The line the Host core makes when it stops with a live session is not lost to the model's own stop.
    func testTheSessionEndOfAStopIsReported() async throws {
        let model = makeModel()
        let events = EventLog()
        events.attach(to: model)
        try await started(model)
        let s = session(name: "Phone")
        let host = try await pair(model, s)
        try await s.open(host: host)
        _ = await waitFor { model.devices.first?.live == true }
        await model.stop()
        XCTAssertEqual(events.sessionEnds.count, 1, "\(events.events)")
        XCTAssertTrue(events.sessionEnds.first?.contains("by host-stop") ?? false, "\(events.sessionEnds)")
    }

    func testAFailureIsReportedOncePerReasonHoweverOftenItIsTried() async throws {
        let (taken, fd) = try occupiedPort()
        let model = makeModel(port: taken, retry: 0.05)
        let events = EventLog()
        events.attach(to: model)
        await model.start()
        let retried = await waitFor { log.attempts >= 4 }
        XCTAssertTrue(retried, "attempts \(log.attempts)")
        XCTAssertEqual(events.failures.count, 1, "\(events.failures)")
        release(fd)
        let up = await waitFor(5) { if case .running = model.phase { true } else { false } }
        XCTAssertTrue(up)
        XCTAssertTrue(events.events.contains(.listening(port: taken)))
    }

    /// The announcer is awaited inside the model's status loop: one whose centre never answers must not hold the status.
    func testStatusMovesWhileTheNotificationCentreNeverAnswers() async throws {
        let model = makeModel(announcing: PairingNotifier(centre: SilentCentre(), title: "Code"))
        try await started(model)
        await model.beginPairing()
        let shown = await waitFor(3) { if case .pairing = model.status { true } else { false } }
        XCTAssertTrue(shown, "status \(model.status)")
        await model.cancelPairing()
        let left = await waitFor(3) { model.status == .idle }
        XCTAssertTrue(left, "status \(model.status)")
        await model.beginPairing()
        let again = await waitFor(3) { if case .pairing = model.status { true } else { false } }
        XCTAssertTrue(again, "status \(model.status)")
    }

    func testAMessageFromOutsideIsShown() async throws {
        let model = makeModel()
        model.show(message: "a file was not used")
        XCTAssertEqual(model.message, "a file was not used")
    }

    // MARK: folders spelled differently

    func testAFolderThatIsAnotherSpellingOfAKnownOneIsNotAddedTwice() async throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-real-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        folders += [real, link]
        let model = makeModel(systemRoots: [URL(fileURLWithPath: "/Applications")])
        await model.addFolder(real)
        await model.addFolder(link)
        XCTAssertEqual(model.settings.folders.count, 1, "\(model.settings.folders)")
        XCTAssertEqual(model.libraryRoots.count, 2)
        // A system folder added by hand is the system folder.
        await model.addFolder(URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(model.settings.folders.count, 1, "\(model.settings.folders)")
    }

    // MARK: failure and retry

    func testStartFailureRetries() async throws {
        let (taken, fd) = try occupiedPort()
        let model = makeModel(port: taken, retry: 0.2)
        await model.start()
        guard case let .failed(reason) = model.phase else { return XCTFail("phase \(model.phase)") }
        XCTAssertEqual(model.message, HostMessages.serviceFailed(reason))
        XCTAssertFalse(reason.isEmpty)
        let retried = await waitFor { log.attempts >= 3 }
        XCTAssertTrue(retried, "attempts \(log.attempts)")
        guard case .failed = model.phase else { return XCTFail("phase \(model.phase)") }
        release(fd)
        let up = await waitFor(5) { if case .running = model.phase { true } else { false } }
        XCTAssertTrue(up, "phase \(model.phase)")
        XCTAssertEqual(try runningPort(model), taken)
        XCTAssertNil(model.message, "the failure is shown no longer once the Host runs")
        XCTAssertEqual(log.overlaps, 0, "two services were alive at once")
        let after = log.attempts
        XCTAssertEqual(log.services.count, after)
        XCTAssertEqual(model.liveServices, 1)
    }

    func testStopDuringARetryWaitLeavesNothingRunning() async throws {
        let (taken, _) = try occupiedPort()
        let model = makeModel(port: taken, retry: 30)  // the wait is the 30 s the test cuts short
        await model.start()
        guard case .failed = model.phase else { return XCTFail("phase \(model.phase)") }
        XCTAssertEqual(log.attempts, 1)
        let began = Date()
        await model.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "stop() waited out the retry interval")
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.liveServices, 0)
        XCTAssertEqual(log.attempts, 1, "a retry came after stop()")
        let stopped = await log.services[0].stopped
        XCTAssertTrue(stopped)
    }

    func testStopDuringAStartIsNotAFailure() async throws {
        let latch = makeLatch()
        log.hold = { await latch.hold() }
        let model = makeModel()
        let starting = Task { await model.start() }
        let reached = await waitFor { latch.entered }
        XCTAssertTrue(reached, "start() never reached the hold")
        XCTAssertEqual(model.phase, .starting)
        let stopping = Task { await model.stop() }
        // The service stops first; the held start then finds it so and throws `CancellationError`.
        let serviceStopped = await waitFor { await log.services.first?.stopped == true }
        XCTAssertTrue(serviceStopped)
        latch.open()
        await stopping.value
        await starting.value
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertNil(model.message, "a start beaten by stop() is no failure")
        XCTAssertEqual(model.liveServices, 0)
        try? await Task.sleep(nanoseconds: 700_000_000)  // the one fixed wait: three retry intervals pass and nothing is made
        XCTAssertEqual(log.attempts, 1, "a retry followed a stop")
        XCTAssertEqual(model.phase, .stopped)
    }

    func testAnUnreadableIdentityIsFailedWithItsOwnSentenceAndNotRetried() async throws {
        try secrets.write("host.identity", Data([1, 2, 3]))
        let model = makeModel(retry: 0.1)
        await model.start()
        XCTAssertEqual(model.phase, .failed(HostMessages.identityUnreadable))
        XCTAssertEqual(model.message, HostMessages.identityUnreadable)
        XCTAssertEqual(log.attempts, 1)
        try? await Task.sleep(nanoseconds: 600_000_000)  // the one fixed wait: six retry intervals pass and nothing is made
        XCTAssertEqual(log.attempts, 1, "an unreadable identity was retried")
        XCTAssertEqual(model.phase, .failed(HostMessages.identityUnreadable))
        // The person starts it again, with the identity gone: it tries once more and runs.
        try secrets.delete("host.identity")
        try await started(model)
        XCTAssertEqual(log.attempts, 2)
        XCTAssertNil(model.message)
    }

    func testNeverTwoServicesAtOnce() async throws {
        let (taken, fd) = try occupiedPort()
        let model = makeModel(port: taken, retry: 0.05)
        await model.start()
        let many = await waitFor { log.attempts >= 5 }
        XCTAssertTrue(many, "attempts \(log.attempts)")
        release(fd)
        let up = await waitFor(5) { if case .running = model.phase { true } else { false } }
        XCTAssertTrue(up, "phase \(model.phase)")
        await model.rename("Another Name")
        await model.stop()
        await model.start()
        await model.stop()
        XCTAssertGreaterThanOrEqual(log.services.count, 7)  // 5 failed attempts at least, then the running one, the rename, the restart
        XCTAssertEqual(log.overlaps, 0, "a service was made while an earlier one was alive")
        XCTAssertEqual(model.liveServices, 0)
        for s in log.services {
            let stopped = await s.stopped
            XCTAssertTrue(stopped)
        }
    }
}

/// A secret store whose writes can be made to fail.
final class FlakySecrets: SecretStoring, @unchecked Sendable {
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
#endif
