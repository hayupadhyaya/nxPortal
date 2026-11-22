#if os(macOS)
import XCTest
import CoreVideo
import Network
import PortalKit
@_spi(Testing) import PortalHostCore
@testable import PortalTestSupport
@testable import PortalClientCore
@testable import PortalPlayer

/// A browser that yields one fixed list; `fail` drives `failures`.
struct StubBrowser: HostBrowsing {
    let hosts: AsyncStream<[FoundHost]>
    let failures: AsyncStream<Bool>
    let fail: AsyncStream<Bool>.Continuation
    /// `restart()` calls.
    let restarts = Counter()
    /// Yields a new list.
    let list: AsyncStream<[FoundHost]>.Continuation
    init(_ found: [FoundHost]) {
        let (stream, out) = AsyncStream.makeStream(of: [FoundHost].self)
        out.yield(found)
        list = out
        hosts = stream
        (failures, fail) = AsyncStream.makeStream(of: Bool.self)
    }
    func start() {}
    func stop() {}
    func restart() { restarts.bump() }
}

/// What `onPicture` delivered, in order.
final class Pictures: @unchecked Sendable {
    struct Shown: Equatable { var frame: UInt32, captureNs: UInt64, width: Int, height: Int }
    private let lock = NSLock()  // guards list
    private var list: [Shown] = []
    func add(_ p: DecodedFrame) {
        let s = Shown(frame: p.frame, captureNs: p.captureNs, width: CVPixelBufferGetWidth(p.pixelBuffer), height: CVPixelBufferGetHeight(p.pixelBuffer))
        lock.withLock { list.append(s) }
    }
    var all: [Shown] { lock.withLock { list } }
    var count: Int { lock.withLock { list.count } }
}

/// Counts calls.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()  // guards n
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// Drops the next datagram the session sees once armed.
/// Drops every incoming datagram while on.
final class DropAll: @unchecked Sendable {
    private let lock = NSLock()  // guards on
    private var on = false
    func set(_ value: Bool) { lock.withLock { on = value } }
    func keep(_ index: Int) -> Bool { lock.withLock { !on } }
}

struct Failed: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// `ClientModel` against a real Host service and the fake game -> .claude/client.md § model
@MainActor
final class ClientModelTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private let hostName = "Test Host"
    private var dir: URL!
    private var launcher: FakeLauncher!
    private var service: HostService!
    private var port: UInt16 = 0
    private var models: [ClientModel] = []
    private var suiteName = ""
    /// This test's own device defaults, never `.standard`.
    private var defaults: UserDefaults!

    override func setUp() async throws {
        // continueAfterFailure stays true: stopping a failed @MainActor async test hangs it. Helpers throw instead.
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-m-" + UUID().uuidString)
        suiteName = "nxp-model-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        launcher = FakeLauncher()
        service = try makeService(port: 0)
        port = try await service.start()
    }

    override func tearDown() async throws {
        for m in models { await m.disconnect() }
        models = []
        await service.stop()
        launcher.game?.stop()
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    /// The Mac's load as a Host test gives it: fixed numbers, nothing read from the machine.
    private struct FixedLoad: LoadSampling {
        mutating func sample(gamePID: Int32?, now: UInt64) -> MacLoadReading {
            var r = MacLoadReading()
            r.cpuTotal = 412; r.cpuPerf = 551; r.cpuEff = 120; r.gpu = 783; r.thermal = 1
            r.memUsedMiB = 18_330; r.memTotalMiB = 32_768; r.gameAlive = true; r.gameCpuCentiCores = 160; r.gameMemMiB = 6_250
            return r
        }
    }

    private func makeService(port: UInt16, name: String? = nil, store: String = "host.json", extraGames: [GameApp] = []) throws -> HostService {
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        var config = HostConfig(
            name: name ?? hostName, storeURL: dir.appendingPathComponent(store), libraryRoots: [],
            launcher: launcher, power: NoPower(), advertise: false, port: port, extraGames: [fake] + extraGames)
        config.loadSampler = { FixedLoad() }
        if !strictOptions { config.settableOption = { _ in true } }  // lists with made-up variables; `strictOptions` = the real gate (`PlayerOptionsTests`)
        let box = answerHook
        config.optionsAnswerHook = { box.change($0) }
        return try HostService(config: config)
    }

    /// A Host stand-in's way of sending what no Host would: changes an options answer on its way out.
    private final class AnswerHook: @unchecked Sendable {  // state behind `lock`
        private let lock = NSLock()
        private var next: [@Sendable (GameOptions) -> GameOptions?] = []
        func once(_ f: @escaping @Sendable (GameOptions) -> GameOptions?) { lock.withLock { next.append(f) } }
        func change(_ o: GameOptions) -> GameOptions? {
            guard let f = lock.withLock({ next.isEmpty ? nil : next.removeFirst() }) else { return o }
            return f(o)
        }
    }
    private let answerHook = AnswerHook()
    private var strictOptions = false

    private var found: FoundHost {
        FoundHost(name: hostName, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    private var fakeEntry: GameEntry { GameEntry(titleID: fakeID, name: "Fake Game", streamable: true, state: .idle) }

    private func model(_ secrets: MemorySecrets = MemorySecrets(), name: String? = "Device 1",
                       retry: TimeInterval = 2, silence: TimeInterval = 3,
                       browser: StubBrowser? = nil, recordings: URL? = nil,
                       retryLimit: TimeInterval = 300, quitWait: TimeInterval = 6, lookup: TimeInterval = 5,
                       cache: LibraryCache? = nil, artCache: ArtCache? = nil,
                       settings: ClientSettings = ClientSettings(), defaults: UserDefaults? = nil) -> (ClientModel, Pictures) {
        let m = ClientModel(store: ClientStore(secrets: secrets), browser: browser ?? StubBrowser([found]), deviceName: name,
                            kind: .tablet, settings: settings, sound: false, retryInterval: retry, silenceTimeout: silence,
                            recordingsDirectory: recordings, retryLimit: retryLimit, quitWait: quitWait,
                            lookupLimit: lookup, cache: cache, artCache: artCache, defaults: defaults ?? self.defaults)
        let pictures = Pictures()
        m.onPicture = { pictures.add($0) }
        m.start()
        models.append(m)
        return (m, pictures)
    }

    /// A model paired with the Host and showing the library.
    private func paired(_ secrets: MemorySecrets = MemorySecrets(), name: String? = "Device 1",
                        retry: TimeInterval = 2, silence: TimeInterval = 3,
                        browser: StubBrowser? = nil, recordings: URL? = nil,
                        retryLimit: TimeInterval = 300, quitWait: TimeInterval = 6,
                        cache: LibraryCache? = nil, artCache: ArtCache? = nil,
                        settings: ClientSettings = ClientSettings(), defaults: UserDefaults? = nil) async throws -> (ClientModel, Pictures) {
        let (m, p) = model(secrets, name: name, retry: retry, silence: silence, browser: browser, recordings: recordings,
                           retryLimit: retryLimit, quitWait: quitWait, cache: cache, artCache: artCache,
                           settings: settings, defaults: defaults)
        await m.choose(found)
        XCTAssertEqual(m.screen, .pairing(found))
        let code = try await service.beginPairing()
        await m.pair(code: code)
        let library = await waitFor { m.screen == .library && !m.games.isEmpty }
        guard library else { throw Failed("not paired: screen \(m.screen), message \(m.message ?? "-")") }
        return (m, p)
    }

    // MARK: device name -> .claude/client.md § settings

    /// The name the test Host holds for the one paired device (its own name, not the Host's rename).
    private func hostsName() async -> String? { await service.devices().first?.name }

    /// The setting's name reaches the Host at pairing, and a changed one at the next connection.
    func testTheDeviceNameSettingReachesTheHostAtPairingAndAtTheNextHello() async throws {
        var settings = ClientSettings()
        settings.deviceName = "Den iPad"
        let (m, _) = try await paired(name: nil, settings: settings)
        let atPairing = await hostsName()
        XCTAssertEqual(atPairing, "Den iPad")
        m.settings.deviceName = "Den iPad 2"
        await m.leave()  // a library session again: a new hello
        var seen = await hostsName()
        for _ in 0..<400 where seen != "Den iPad 2" {
            try await Task.sleep(nanoseconds: 10_000_000)
            seen = await hostsName()
        }
        XCTAssertEqual(seen, "Den iPad 2")
    }

    /// An empty or blank setting sends the model's name; a dirty one is cleaned before it is sent.
    func testTheDeviceNameIsTheModelsNameUnlessTheSettingSaysOtherwise() {
        let (m, _) = model(name: nil)
        XCTAssertEqual(m.deviceName, DeviceModelName.current())
        XCTAssertFalse(m.deviceName.isEmpty)
        m.settings.deviceName = "  \n "
        XCTAssertEqual(m.deviceName, DeviceModelName.current(), "blank is the model's name")
        m.settings.deviceName = "\u{7}Den\u{202E}   iPad "
        XCTAssertEqual(m.deviceName, "Den iPad")
        let (named, _) = model(name: "Test iPad")
        XCTAssertEqual(named.deviceName, "Test iPad", "the init's name is an override for tests")
    }

    /// The model's name is what a Host sees from a device that was never given a name.
    func testWithoutASettingTheHostGetsTheModelsName() async throws {
        let (_, _) = try await paired(name: nil)
        let seen = await hostsName()
        XCTAssertEqual(seen, DeviceModelName.current())
    }

    // MARK: stream size

    private func restartHost(_ l: FakeLauncher) async throws {
        await service.stop()
        launcher = l
        service = try makeService(port: 0)
        port = try await service.start()
    }

    /// The game's own size caps what the app claims; it is kept per title on this device and outlives the model.
    func testTheEffectiveSizeIsTheGamesOwnAndIsRemembered() async throws {
        try await restartHost(FakeLauncher(width: 1920, height: 1080))
        var settings = ClientSettings()
        settings.maxWidth = 2560; settings.maxHeight = 1440
        let (m, p) = try await paired(settings: settings)
        XCTAssertEqual(m.effectiveStreamSize.width, 2560, "nothing known before the game's first picture")
        try await play(m, p)
        let known = await waitFor { m.knownRender[self.fakeID] != nil }
        XCTAssertTrue(known)
        XCTAssertEqual(m.knownRender[fakeID], RenderSize(width: 1920, height: 1080, exact: true))
        let e = m.effectiveStreamSize
        XCTAssertEqual(e.width, 1920); XCTAssertEqual(e.height, 1080); XCTAssertEqual(e.reason, "this game's own size")
        XCTAssertEqual(m.settings.maxWidth, 2560, "the saved cap is not rewritten")
        let (n, _) = model(defaults: defaults)
        XCTAssertEqual(n.knownRender[fakeID], RenderSize(width: 1920, height: 1080, exact: true), "a new model on the same defaults")
    }

    private func report(_ m: ClientModel, _ id: String, _ w: UInt16, _ h: UInt16, exact: Bool) {
        m.noteRender(GameState(titleID: id, run: .running, reason: nil, render: RenderSize(width: w, height: h, exact: exact)))
    }
    private func report(_ m: ClientModel, _ w: UInt16, _ h: UInt16, exact: Bool) { report(m, fakeID, w, h, exact: exact) }

    /// A report with a zero side, under the minimum or absurdly large is not shown, stored or used to disable anything.
    func testBadRenderReportsAreIgnored() {
        var settings = ClientSettings()
        settings.maxWidth = 2560; settings.maxHeight = 1440
        let (m, _) = model(settings: settings)
        for (w, h) in [(UInt16(0), UInt16(0)), (1920, 0), (100, 50), (65535, 65535)] { report(m, w, h, exact: true) }
        XCTAssertTrue(m.knownRender.isEmpty)
        XCTAssertTrue(m.sizeOffers(for: fakeID).allSatisfy(\.enabled))
        XCTAssertEqual(m.effectiveStreamSize(for: fakeID).width, 2560)
        XCTAssertFalse(m.showsSizeLine(for: fakeID))
        XCTAssertNil(m.sizeNote(for: fakeID))
        report(m, 1920, 1080, exact: true)
        m.noteRender(GameState(titleID: "bad id", run: .running, reason: nil, render: RenderSize(width: 1280, height: 720, exact: true)))
        XCTAssertEqual(Array(m.knownRender.keys), [fakeID], "a malformed title ID is not kept")
    }

    func testTheRenderMergeRulesThroughTheModel() {
        let (m, _) = model()
        report(m, 1920, 1080, exact: true)
        report(m, 1280, 720, exact: false)
        XCTAssertEqual(m.knownRender[fakeID], RenderSize(width: 1920, height: 1080, exact: true), "a lower bound under it does not replace it")
        report(m, 1280, 720, exact: true)
        XCTAssertEqual(m.knownRender[fakeID], RenderSize(width: 1280, height: 720, exact: true), "a new exact size replaces")
        report(m, 1920, 1080, exact: false)
        XCTAssertEqual(m.knownRender[fakeID], RenderSize(width: 1920, height: 1080, exact: false), "a larger lower bound replaces")
    }

    /// The offers, the note, the line and the page's condition; a saved cap above the game stays selected, shown disabled.
    func testTheSizeOffersTheNoteAndTheLine() {
        var settings = ClientSettings()
        settings.maxWidth = 2560; settings.maxHeight = 1440
        let (m, _) = model(settings: settings)
        XCTAssertFalse(m.showsSizeLine(for: fakeID))
        XCTAssertNil(m.sizeNote(for: fakeID))
        XCTAssertEqual(m.streamSizeLine(for: fakeID), "2560 × 1440 · your size setting")
        XCTAssertTrue(m.sizeOffers(for: fakeID).allSatisfy(\.enabled))
        report(m, 1920, 1080, exact: true)
        XCTAssertTrue(m.showsSizeLine(for: fakeID))
        XCTAssertFalse(m.showsSizeLine(for: "OTHER00000000000"))
        XCTAssertEqual(m.sizeOffers(for: fakeID).map { "\($0.size.width)x\($0.size.height) \($0.enabled)" },
                       ["1280x720 true", "1920x1080 true", "2560x1440 false"])
        XCTAssertEqual(m.streamSizeLine(for: fakeID), "1920 × 1080 · this game's own size")
        XCTAssertEqual(m.sizeNote(for: fakeID), "1920 × 1080 · this game's own size\nAbove what this game renders")
        XCTAssertEqual(m.settings.maxWidth, 2560, "the saved cap is the picker's value, not rewritten")
        XCTAssertEqual(SettingsChoices.sizes(for: m.settings).contains(SettingsChoices.Size(width: 2560, height: 1440)), true)
        XCTAssertNil(m.sizeNote(for: nil))
    }

    /// Every report counts as a use, also one that changes nothing: the title seen longest ago is the one dropped.
    func testTheBoundDropsTheTitleSeenLongestAgo() {
        let (m, _) = model()
        func id(_ i: Int) -> String { String(format: "T%015d", i) }
        for i in 0..<RenderMemory.limit { report(m, id(i), 1280, 720, exact: true) }
        report(m, id(0), 1280, 720, exact: true)  // nothing changes, the title is used
        report(m, id(RenderMemory.limit), 1280, 720, exact: true)
        XCTAssertNotNil(m.knownRender[id(0)], "used again, so kept")
        XCTAssertNil(m.knownRender[id(1)], "seen longest ago, dropped")
        XCTAssertEqual(m.knownRender.count, RenderMemory.limit)
    }

    func testKnownRenderIsBoundedAndKeepsTheNewest() {
        let (m, _) = model()
        for i in 0..<(RenderMemory.limit + 5) { report(m, String(format: "T%015d", i), 1280, 720, exact: true) }
        XCTAssertEqual(m.knownRender.count, RenderMemory.limit)
        XCTAssertNil(m.knownRender[String(format: "T%015d", 0)], "the oldest is dropped")
        XCTAssertNotNil(m.knownRender[String(format: "T%015d", RenderMemory.limit + 4)])
        let (n, _) = model(defaults: defaults)
        XCTAssertEqual(n.knownRender.count, RenderMemory.limit, "and it is what was stored")
    }

    /// Launches the fake game and waits for pictures.
    private func play(_ m: ClientModel, _ p: Pictures) async throws {
        await m.launch(fakeEntry)
        let playing = await waitFor { m.screen == .playing && p.count >= 5 }
        guard playing else { throw Failed("not playing: screen \(m.screen), pictures \(p.count), message \(m.message ?? "-")") }
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    private func isRestart(_ frame: UInt32) -> Bool {
        isKey(frame) || launcher.game?.sentFrames[frame]?.mark == .repair
    }

    private func isKey(_ frame: UInt32) -> Bool {
        guard let data = launcher.game?.sentVideo[frame] else { return false }
        return HEVC.parameterSets(data) != nil
    }

    private func pausedOnHost() async -> Bool {
        guard let game = launcher.game else { return false }
        return await waitFor(1) { game.received.contains(.pause(true)) }
    }

    // MARK: pairing

    func testPairThenLibrary() async throws {
        let secrets = MemorySecrets()
        let (m, _) = try await paired(secrets)
        XCTAssertTrue(m.games.contains { $0.titleID == fakeID })
        XCTAssertNil(m.message)
        XCTAssertEqual(try ClientStore(secrets: secrets).hosts().map(\.name), [hostName])
        XCTAssertEqual(m.found, [found])
    }

    func testWrongCodeStaysOnPairing() async throws {
        let (m, _) = model()
        await m.choose(found)
        let code = try await service.beginPairing()
        await m.pair(code: code == "000000" ? "000001" : "000000")
        XCTAssertEqual(m.message, Messages.pairing(.wrongCode(triesLeft: PairingLimits.tries - 1)))
        XCTAssertEqual(m.screen, .pairing(found))
    }

    /// The red text and the retry line go together: editing the code clears both.
    func testEditingTheCodeClearsTheRefusal() async throws {
        let (m, _) = model()
        await m.choose(found)
        let code = try await service.beginPairing()
        await m.pair(code: code == "000000" ? "000001" : "000000")
        XCTAssertEqual(m.pairingResult, .wrongCode(triesLeft: PairingLimits.tries - 1))
        XCTAssertTrue(m.pairingRejected)
        XCTAssertNotNil(m.message)
        m.codeEdited()
        XCTAssertFalse(m.pairingRejected)
        XCTAssertNil(m.message)
        XCTAssertNil(m.pairingResult)
        XCTAssertEqual(m.screen, .pairing(found))
    }

    func testSecondStartNeedsNoCode() async throws {
        let secrets = MemorySecrets()
        let (first, _) = try await paired(secrets)
        await first.disconnect()
        let (m, _) = model(secrets)
        await m.choose(found)
        let library = await waitFor { m.screen == .library }
        XCTAssertTrue(library, "screen \(m.screen), message \(m.message ?? "-")")
    }

    // MARK: last Mac

    private func foundHost(_ name: String, port: UInt16, id: String? = nil) -> FoundHost {
        FoundHost(name: name, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), id: id)
    }

    /// Pairs `secrets`' device with `svc` and stores the Mac as `name`; returns it. The last Mac is left unset.
    private func pairWith(_ svc: HostService, port: UInt16, secrets: MemorySecrets, as name: String) async throws -> PairedPeer {
        let (m, _) = model(secrets, browser: StubBrowser([]))
        await m.choose(foundHost("probe", port: port))
        let code = try await svc.beginPairing()
        await m.pair(code: code)
        let ok = await waitFor { m.screen == .library && m.macState == .connected }
        guard ok else { throw Failed("not paired: screen \(m.screen), message \(m.message ?? "-")") }
        await m.disconnect()
        let store = ClientStore(secrets: secrets)
        let key = try XCTUnwrap(try store.hosts().last?.key)
        let peer = PairedPeer(key: key, name: name)
        try store.save(host: peer)
        try store.setLast(hostKey: nil)
        return peer
    }

    /// A second Host with its own store; stopped by the caller.
    private func secondHost(name: String) async throws -> (HostService, UInt16) {
        let svc = try makeService(port: 0, name: name, store: "host-2.json")
        return (svc, try await svc.start())
    }

    func testStartOpensTheLastMacsLibraryAndNeverShowsHosts() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: b.key)
        let browser = StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key)),
                                   foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))])
        let (m, _) = model(secrets, browser: browser)
        var seen = [m.screen]
        // No cache here: the games arrive with the first list reply, after the Mac turns connected.
        let connected = await waitFor { if seen.last != m.screen { seen.append(m.screen) }; return m.macState == .connected && !m.games.isEmpty }
        XCTAssertTrue(connected, "screen \(m.screen), state \(m.macState), message \(m.message ?? "-")")
        XCTAssertEqual(seen, [.library])
        XCTAssertEqual(m.hostName, "Mac B")
        XCTAssertEqual(m.current, b)
        XCTAssertTrue(m.games.contains { $0.titleID == fakeID })
        XCTAssertTrue(m.gamesListed, "the first list came")
        XCTAssertFalse(m.libraryLoading)
        m.show(b)  // another Mac's library shows before its list: loading, never "no games"
        XCTAssertFalse(m.gamesListed)
        XCTAssertTrue(m.libraryLoading)
    }

    func testAListThatFailsStopsSayingLoadingAndRetryListsAgain() async throws {
        let (m, _) = try await paired()
        let id = try XCTUnwrap(m.link?.id)
        // The connect's list and the one after the admission's game state are both answered before `show()` resets the
        // flags: a reply landing after the reset would be that Mac's list, correctly, and not this test's failure.
        let settled = await waitFor { m.listAsked >= 2 && m.listShown == m.listAsked }
        XCTAssertTrue(settled, "asked \(m.listAsked), shown \(m.listShown)")
        m.show(try XCTUnwrap(m.current))  // no games yet, no list: loading
        XCTAssertTrue(m.libraryLoading)
        XCTAssertFalse(m.libraryCouldNotLoad)
        let l = try XCTUnwrap(m.link)
        await l.session.close()  // the list request now fails
        await m.listGames(link: id)
        XCTAssertFalse(m.libraryLoading, "a failed list is not 'loading' for ever")
        XCTAssertFalse(m.gamesListed)
        // Closing the session also ends the link, on its own task: either that was handled first (the library then shows
        // the Mac as not connected: not "could not load" but its own state) or the list's failure was seen on the live link.
        if m.link != nil, m.macState == .connected {
            XCTAssertTrue(m.libraryCouldNotLoad)
        } else {
            XCTAssertNotEqual(m.macState, .connected, "the link ended first: the library says the Mac is not connected, not 'loading'")
            XCTAssertFalse(m.libraryLoading)
        }
        m.show(try XCTUnwrap(m.current))
        XCTAssertFalse(m.libraryCouldNotLoad, "another library starts fresh")
    }

    func testLastMacNotListedIsUnreachableThenRetryConnects() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: b.key)
        let cache = LibraryCache(directory: dir.appendingPathComponent("cache"))
        cache.save([fakeEntry], for: b.key)
        let browser = StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key))])
        let (m, _) = model(secrets, browser: browser, lookup: 0.25, cache: cache)
        XCTAssertEqual(m.macState, .looking)
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.games, [fakeEntry], "the cached games show while looking")
        let gone = await waitFor { m.macState == .unreachable }
        XCTAssertTrue(gone, "state \(m.macState)")
        XCTAssertEqual(m.message, "Cannot reach Mac B.")
        XCTAssertEqual(m.games, [fakeEntry])
        XCTAssertEqual(m.screen, .library)
        browser.list.yield([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key)),
                            foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))])
        let listed = await waitFor { m.found.count == 2 }
        XCTAssertTrue(listed)
        await m.retry()
        XCTAssertEqual(m.macState, .connected, "message \(m.message ?? "-")")
        XCTAssertNil(m.message)
        XCTAssertEqual(browser.restarts.value, 1)
    }

    func testNoPairedMacIsFirstRunAndDiscoveryRefusedIsSeen() async throws {
        let browser = StubBrowser([])
        let (m, _) = model(browser: browser)
        XCTAssertEqual(m.screen, .hosts)
        XCTAssertNotNil(m.lookingSince)
        XCTAssertNil(m.discoveryMessage)
        browser.fail.yield(true)
        let blocked = await waitFor { m.discoveryMessage != nil }
        XCTAssertTrue(blocked)
    }

    func testOnePairedMacWithoutALastBecomesCurrent() async throws {
        let secrets = MemorySecrets()
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))]))
        XCTAssertEqual(m.current, b)
        XCTAssertEqual(m.screen, .library)
        let connected = await waitFor { m.macState == .connected }
        XCTAssertTrue(connected, "state \(m.macState)")
    }

    /// C3: a Mac renamed on the Mac is still the last Mac: found by id, and the stored name follows.
    func testRenamedLastMacOpensAndTheStoredNameFollows() async throws {
        let secrets = MemorySecrets()
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: b.key)
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac B (2)", port: port, id: Identity.discoveryID(publicKey: b.key))]))
        let connected = await waitFor { m.macState == .connected }
        XCTAssertTrue(connected, "state \(m.macState), message \(m.message ?? "-")")
        XCTAssertEqual(try ClientStore(secrets: secrets).hosts().map(\.name), ["Mac B (2)"])
        XCTAssertEqual(m.hostName, "Mac B (2)")
    }

    /// Mac B's open is held (a listener that accepts and never answers); a switch to Mac A runs meanwhile; B's late
    /// failure, when the connection is dropped, changes nothing.
    func testSwitchMacWhileAConnectIsInFlightIgnoresTheLateResult() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: b.key)
        let listener = try NWListener(using: .tcp, on: .any)
        let held = HeldConnections()
        listener.newConnectionHandler = { c in held.add(c); c.start(queue: .global()) }
        let ready = Counter()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.bump() } }
        listener.start(queue: .global())
        defer { listener.cancel(); held.cancelAll() }
        let up = await waitFor(3) { ready.value > 0 }
        XCTAssertTrue(up)
        let idA = Identity.discoveryID(publicKey: a.key), idB = Identity.discoveryID(publicKey: b.key)
        let silentB = foundHost("Mac B", port: try XCTUnwrap(listener.port?.rawValue), id: idB)
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac A", port: portA, id: idA), silentB]))
        let inFlight = await waitFor { held.count > 0 }
        XCTAssertTrue(inFlight, "the open of Mac B never started: state \(m.macState)")
        XCTAssertEqual(m.macState, .connecting)
        let rowA = try XCTUnwrap(m.macRows.first { $0.name == "Mac A" })
        await m.switchMac(rowA)
        XCTAssertEqual(m.macState, .connected, "message \(m.message ?? "-")")
        XCTAssertEqual(m.hostName, "Mac A")
        held.cancelAll()  // B's attempt ends now, late
        await sleep(0.4)
        XCTAssertEqual(m.macState, .connected)
        XCTAssertEqual(m.hostName, "Mac A")
        XCTAssertEqual(m.current, a)
        XCTAssertNil(m.message)
        XCTAssertEqual(m.screen, .library)
        XCTAssertTrue(m.games.contains { $0.titleID == fakeID })
    }

    /// A failed switch is the new Mac's: its name, its own games (none cached), its sentence; never the old Mac's games.
    func testAFailedSwitchLandsOnTheNewMacsLibrary() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: a.key)
        let (other, otherPictures) = try await paired(name: "Device 9")
        try await play(other, otherPictures)
        let cache = LibraryCache(directory: dir.appendingPathComponent("cache"))
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key)),
                                                          foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))]), cache: cache)
        let onA = await waitFor { m.macState == .connected }
        XCTAssertTrue(onA, "state \(m.macState), message \(m.message ?? "-")")
        let listed = await waitFor { !m.games.isEmpty }
        XCTAssertTrue(listed)
        let rowB = try XCTUnwrap(m.macRows.first { $0.name == "Mac B" })
        await m.switchMac(rowB)
        XCTAssertEqual(m.macState, .unreachable)
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.hostName, "Mac B")
        XCTAssertEqual(m.current, b)
        XCTAssertEqual(m.message, "Mac B is playing on Device 9.")
        XCTAssertTrue(m.games.isEmpty, "Mac A's games are shown under Mac B's name")
        XCTAssertEqual(m.problem, .refused(.busy(device: "Device 9")))
        XCTAssertEqual(Messages.banner(try XCTUnwrap(m.problem), mac: try XCTUnwrap(m.hostName)), "Mac B is playing on Device 9.")
        XCTAssertEqual(try ClientStore(secrets: secrets).lastHostKey(), a.key, "only a connect that succeeded sets the last Mac")
    }

    func testChoosingAnUnpairedMacKeepsTheOpenSessionUntilCancelled() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        try ClientStore(secrets: secrets).setLast(hostKey: a.key)
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key))]))
        let onA = await waitFor { m.macState == .connected && !m.games.isEmpty }
        XCTAssertTrue(onA, "state \(m.macState)")
        let before = try XCTUnwrap(m.session)
        let games = m.games
        let unpaired = foundHost("Mac B", port: port, id: "BBBBBBBBBBBBBBBB")
        await m.choose(unpaired)
        XCTAssertEqual(m.screen, .pairing(unpaired))
        XCTAssertNotNil(m.session, "the open session was closed for a pairing")
        m.cancelPairing()
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .connected)
        XCTAssertNil(m.message)
        XCTAssertTrue(m.session === before, "the session is no longer Mac A's")
        XCTAssertEqual(m.games, games)
        XCTAssertEqual(m.hostName, "Mac A")
    }

    func testPairingSucceedingClosesTheOldSessionAndShowsTheNewMac() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        try ClientStore(secrets: secrets).setLast(hostKey: a.key)
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key))]))
        let onA = await waitFor { m.macState == .connected }
        XCTAssertTrue(onA)
        let before = try XCTUnwrap(m.session)
        await m.choose(found)
        XCTAssertEqual(m.screen, .pairing(found))
        await m.pair(code: try await service.beginPairing())
        let onB = await waitFor { m.macState == .connected && m.hostName == hostName }
        XCTAssertTrue(onB, "state \(m.macState), name \(m.hostName ?? "-"), message \(m.message ?? "-")")
        XCTAssertFalse(m.session === before)
        XCTAssertEqual(m.screen, .library)
    }

    /// The Mac forgot this device: at launch the pairing sheet opens for it and it leaves the store; cancelling with no
    /// other Mac paired is the first-run screen, never that Mac's library.
    func testAMacThatUnpairedThisDeviceIsForgottenAtLaunch() async throws {
        let secrets = MemorySecrets()
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: b.key)
        try await service.removeDevice(try ClientStore(secrets: secrets).identity().publicKey)
        let host = foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))
        let (m, _) = model(secrets, browser: StubBrowser([host]))
        let asked = await waitFor { if case .pairing = m.screen { true } else { false } }
        XCTAssertTrue(asked, "screen \(m.screen), state \(m.macState), message \(m.message ?? "-")")
        XCTAssertEqual(m.screen, .pairing(host))
        XCTAssertEqual(try ClientStore(secrets: secrets).hosts(), [], "the Mac stayed stored")
        XCTAssertNotNil(m.message)
        XCTAssertFalse(m.pairingRejected, "the sheet of a Mac that forgot this device opens neutral")
        m.cancelPairing()
        XCTAssertEqual(m.screen, .hosts)
        XCTAssertNil(m.current)
    }

    func testAMacThatUnpairedThisDeviceIsForgottenOnASwitchAndTheOtherMacShows() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: a.key)
        try await service.removeDevice(try ClientStore(secrets: secrets).identity().publicKey)
        let hostB = foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key)), hostB]))
        let onA = await waitFor { m.macState == .connected }
        XCTAssertTrue(onA)
        await m.choose(hostB)
        XCTAssertEqual(m.screen, .pairing(hostB))
        XCTAssertEqual(try ClientStore(secrets: secrets).hosts().map(\.name), ["Mac A"])
        m.cancelPairing()
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.hostName, "Mac A")
    }

    /// `start()` interrupted by `background()` is resumed by `foreground()`.
    func testForegroundResumesAStartThatBackgroundInterrupted() async throws {
        let secrets = MemorySecrets()
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: b.key)
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))]))
        await m.background()
        await m.foreground()
        let on = await waitFor { m.macState == .connected }
        XCTAssertTrue(on, "state \(m.macState), screen \(m.screen), message \(m.message ?? "-")")
    }

    /// The last Mac's record is gone (deleted while the app was closed): the first paired Mac, else first run.
    func testALastMacThatIsNoLongerPairedFallsBackToTheFirstPairedMacElseFirstRun() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        let store = ClientStore(secrets: secrets)
        try store.setLast(hostKey: b.key)
        try store.remove(hostKey: b.key)
        let (m, _) = model(secrets, browser: StubBrowser([]), lookup: 0.1)
        XCTAssertEqual(m.current, a)
        XCTAssertEqual(m.screen, .library)
        try store.remove(hostKey: a.key)
        let (none, _) = model(secrets, browser: StubBrowser([]))
        XCTAssertNil(none.current)
        XCTAssertEqual(none.screen, .hosts)
    }

    // MARK: a pairing sheet over a Mac that is open

    private func unpairedHost() async throws -> (HostService, FoundHost) {
        let (svc, port) = try await secondHost(name: "Host Unpaired")
        return (svc, foundHost("Mac Unpaired", port: port, id: "CCCCCCCCCCCCCCCC"))
    }

    func testAWrongCodeForAnotherMacLeavesTheOpenMacConnectedAndTheSheetOpen() async throws {
        let (m, _) = try await paired()
        let session = try XCTUnwrap(m.session)
        let (svc, other) = try await unpairedHost()
        defer { Task { await svc.stop() } }
        await m.choose(other)
        let code = try await svc.beginPairing()
        await m.pair(code: code == "000000" ? "000001" : "000000")
        XCTAssertEqual(m.screen, .pairing(other))
        XCTAssertTrue(m.pairingRejected)
        XCTAssertEqual(m.macState, .connected)
        XCTAssertTrue(m.session === session, "the open Mac was closed by a failed pairing")
        XCTAssertEqual(m.hostName, hostName)
    }

    func testASheetOverALostMacLeavesItsReconnectLoopRunning() async throws {
        let (m, _) = try await paired(retry: 0.2, silence: 0.5)
        await service.stop()
        let lost = await waitFor(4) { m.reconnecting }
        XCTAssertTrue(lost)
        let (svc, other) = try await unpairedHost()
        defer { Task { await svc.stop() } }
        await m.choose(other)
        XCTAssertEqual(m.screen, .pairing(other))
        XCTAssertTrue(m.reconnecting, "opening the sheet cancelled the reconnect loop")
        service = try makeService(port: port)
        _ = try await service.start()
        let back = await waitFor(5) { m.macState == .connected }
        XCTAssertTrue(back, "state \(m.macState), message \(m.message ?? "-")")
        XCTAssertEqual(m.screen, .pairing(other), "the reconnect closed the sheet")
        m.cancelPairing()
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .connected)
        XCTAssertTrue(m.reconnecting == false)
    }

    /// A background and foreground while a sheet is open over a Mac being regained: closing the sheet takes up the reconnect.
    func testABackgroundUnderASheetDoesNotLeaveTheLibraryConnectingAfterIt() async throws {
        let (m, _) = try await paired(retry: 0.2, silence: 0.5)
        await service.stop()
        let lost = await waitFor(4) { m.reconnecting }
        XCTAssertTrue(lost)
        let (svc, other) = try await unpairedHost()
        defer { Task { await svc.stop() } }
        await m.choose(other)
        XCTAssertEqual(m.screen, .pairing(other))
        await m.background()
        await m.foreground()
        XCTAssertEqual(m.screen, .pairing(other), "the sheet stays through the background")
        service = try makeService(port: port)
        _ = try await service.start()
        m.cancelPairing()
        XCTAssertEqual(m.screen, .library)
        let back = await waitFor(5) { m.macState == .connected }
        XCTAssertTrue(back, "state \(m.macState), message \(m.message ?? "-"): nothing reconnects")
    }

    func testTheGiveUpUnderASheetKeepsTheSheetAndShowsUnreachableAfterIt() async throws {
        let (m, _) = try await paired(retry: 0.2, silence: 0.5, retryLimit: 1)
        await service.stop()
        let lost = await waitFor(4) { m.reconnecting }
        XCTAssertTrue(lost)
        let (svc, other) = try await unpairedHost()
        defer { Task { await svc.stop() } }
        await m.choose(other)
        let gaveUp = await waitFor(6) { m.macState == .unreachable }
        XCTAssertTrue(gaveUp, "state \(m.macState)")
        XCTAssertEqual(m.screen, .pairing(other), "the sheet was closed under the person")
        m.cancelPairing()
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .unreachable)
        XCTAssertEqual(m.message, Messages.sentence(.stoppedAnswering, mac: hostName))
    }

    func testOpeningAndCancellingASheetKeepsTheQuitTimer() async throws {
        let (m, _) = try await paired()
        m.quitAsked = true
        m.quitTask = Task { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { m.quitTask?.cancel() }
        let (svc, other) = try await unpairedHost()
        defer { Task { await svc.stop() } }
        await m.choose(other)
        XCTAssertEqual(m.quitTask?.isCancelled, false, "the sheet cancelled the quit timer")
        m.cancelPairing()
        XCTAssertEqual(m.quitTask?.isCancelled, false)
        XCTAssertTrue(m.quitAsked)
    }

    /// The last Mac is the last that connected: a failed switch does not change what the next launch opens.
    func testAFailedSwitchDoesNotChangeWhatTheNextLaunchOpens() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: a.key)
        let browser = StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key)),
                                   foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))])
        let (m, _) = model(secrets, browser: browser)
        let onA = await waitFor { m.macState == .connected }
        XCTAssertTrue(onA)
        await service.stop()  // Mac B is off
        let rowB = try XCTUnwrap(m.macRows.first { $0.name == "Mac B" })
        await m.switchMac(rowB)
        XCTAssertEqual(m.hostName, "Mac B", "for this run the failed Mac is current")
        XCTAssertEqual(m.macState, .unreachable)
        XCTAssertEqual(try ClientStore(secrets: secrets).lastHostKey(), a.key)
        let (again, _) = model(secrets, browser: StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key))]))
        XCTAssertEqual(again.current, a)
        let reopened = await waitFor { again.macState == .connected }
        XCTAssertTrue(reopened, "state \(again.macState)")
    }

    /// Y acts on the focused tile only; with none focused nothing opens, even with a last played game.
    func testTheOptionsTargetIsTheFocusedListedGameOnly() async throws {
        let (m, _) = try await paired()
        m.lastPlayedTile = fakeID
        XCTAssertNil(m.optionsTarget(focused: nil))
        XCTAssertEqual(m.optionsTarget(focused: fakeID), fakeID)
        XCTAssertNil(m.optionsTarget(focused: "NOTLISTED0000000"))
    }

    func testMacRowsListPairedThenFoundByName() async throws {
        let secrets = MemorySecrets()
        let store = ClientStore(secrets: secrets)
        let a = PairedPeer(key: Identity().publicKey, name: "Mac A"), b = PairedPeer(key: Identity().publicKey, name: "Mac B")
        try store.save(host: a); try store.save(host: b); try store.setLast(hostKey: b.key)
        let (m, _) = model(secrets, browser: StubBrowser([foundHost("Mac B", port: port), foundHost("Mac C", port: port)]))
        let listed = await waitFor { m.found.count == 2 }
        XCTAssertTrue(listed)
        let rows = m.macRows
        XCTAssertEqual(rows.map(\.name), ["Mac A", "Mac B", "Mac C"])
        XCTAssertEqual(rows.map(\.paired), [true, true, false])
        XCTAssertEqual(rows.map(\.reachable), [false, true, true])
        XCTAssertEqual(rows.map(\.current), [false, true, false])
        XCTAssertEqual(rows[0].id, Identity.discoveryID(publicKey: a.key))
        XCTAssertEqual(rows[2].id, "Mac C")
    }

    func testWrongCodeWithTwoTriesLeftSaysSo() async throws {
        let (m, _) = model()
        await m.choose(found)
        let code = try await service.beginPairing()
        await m.pair(code: code == "000000" ? "000001" : "000000")
        XCTAssertEqual(PairingLimits.tries, 3)
        XCTAssertEqual(m.message, "That code didn't match. 2 tries left.")
        XCTAssertEqual(m.screen, .pairing(found))
    }

    func testPairingSentences() {
        XCTAssertEqual(Messages.wrongCode(triesLeft: 3), "That code didn't match.")
        XCTAssertEqual(Messages.wrongCode(triesLeft: 1), "That code didn't match. 1 try left.")
        XCTAssertEqual(Messages.pairing(.locked, mac: "Den Mac"), "Too many wrong codes. Show a new code on Den Mac and try again.")
        XCTAssertEqual(Messages.pairing(.expired, mac: "Den Mac"), "The code ran out. Show a new code on Den Mac.")
    }

    // MARK: play

    func testLaunchShowsPictures() async throws {
        let (m, p) = try await paired()
        await m.launch(fakeEntry)
        let playing = await waitFor { m.screen == .playing }
        XCTAssertTrue(playing, "screen \(m.screen)")
        let start = Date()
        let thirty = await waitFor(2) { p.count >= 30 }
        XCTAssertTrue(thirty, "\(p.count) pictures in \(Date().timeIntervalSince(start)) s")
        let shown = p.all
        XCTAssertTrue(shown.allSatisfy { $0.width == 1280 && $0.height == 720 }, "sizes \(Set(shown.map { "\($0.width)x\($0.height)" }))")
        for (a, b) in zip(shown, shown.dropFirst()) { XCTAssertEqual(b.frame, a.frame + 1) }
        let fast = await waitFor(4) { (m.stats?.fps ?? 0) > 30 }
        XCTAssertTrue(fast, "fps \(m.stats?.fps ?? -1)")
        XCTAssertEqual(m.gameState?.run, .running)

        // Input and display hand-offs reach the session.
        m.send(InputState(seq: 0, player: 0, buttons: 1, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil))
        let game = try XCTUnwrap(launcher.game)
        let pressed = await waitFor(1) { game.received.contains { if case .pad(0, 1, _, _, _, _) = $0 { true } else { false } } }
        XCTAssertTrue(pressed, "input did not reach the game")
        // The view's time travels with the mark: 5 s after capture on the Host's clock (no real delay is that long).
        let session = try XCTUnwrap(m.session)
        let synced = await waitFor(2) { (m.stats?.clockOffsetNs ?? 0) != 0 || (m.stats?.p95DelayMs ?? 0) > 0 }
        XCTAssertTrue(synced, "no pong yet")
        let offset = await session.stats().clockOffsetNs
        let displayedBefore = await session.stats().framesDisplayed
        for shown in p.all.suffix(30) {
            m.picturesShown(captureNs: shown.captureNs, at: UInt64(Int64(shown.captureNs) + 5_000_000_000 - offset))
        }
        let marked = await waitFor(2) { (m.stats?.framesDisplayed ?? 0) >= displayedBefore + 30 }
        XCTAssertTrue(marked, "display hand-offs did not reach the session")
        let s = await session.stats()
        XCTAssertEqual(s.framesDisplayed, displayedBefore + 30)
        XCTAssertEqual(s.p95DisplayMs, 5000, accuracy: 1, "the display time was not the view's")
        XCTAssertTrue(m.pictureShown)
    }

    /// A dropped window reports `seconds: 0`: no rate, but its late pictures stay in the total.
    func testLateTotalSurvivesADroppedWindow() async throws {
        let (m, _) = try await paired()
        m.displayCounts(shown: 5, late: 3, empty: 0, seconds: 0)
        XCTAssertEqual(m.latePictures, 3)
        m.displayCounts(shown: 58, late: 2, empty: 2, seconds: 1)
        XCTAssertEqual(m.latePictures, 5)
    }

    /// The panel's and the `stat` line's repair numbers come straight from the session's counters.
    func testPlayStatsCarryTheRepairNumbers() {
        var s = SessionStats()
        s.fragmentsAsked = 20; s.fragmentsRecovered = 17; s.framesRepaired = 5; s.framesGivenUp = 4
        s.repairRequests = 6; s.escalations = 1; s.keys = 2
        s.rateChanges = [RateChange(seq: 1, atSeconds: 0, fromBps: 25_000_000, toBps: 25_000_000, why: .start),
                         RateChange(seq: 2, atSeconds: 3, fromBps: 25_000_000, toBps: 17_500_000, why: .loss)]
        var p = ClientModel.PlayStats()
        p.fill(from: s, queueTarget: 1)
        XCTAssertEqual(p.fragmentsAsked, 20); XCTAssertEqual(p.fragmentsRecovered, 17)
        XCTAssertEqual(p.framesRepaired, 5); XCTAssertEqual(p.framesGivenUp, 4)
        XCTAssertEqual(p.repairRequests, 6); XCTAssertEqual(p.escalations, 1); XCTAssertEqual(p.keys, 2)
        XCTAssertEqual(p.rateWhy, "loss")
        XCTAssertEqual(p.queueTarget, 1)
        var none = ClientModel.PlayStats()
        none.fill(from: SessionStats(), queueTarget: 0)
        XCTAssertEqual(none.rateWhy, "")
    }

    /// A play with a folder writes a header and one line a second; the setting off writes nothing.
    func testPlayWritesSessionFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (m, p) = try await paired(recordings: dir)
        try await play(m, p)
        let wrote = await waitFor(6) {
            guard let f = try? FileManager.default.contentsOfDirectory(atPath: dir.path).first,
                  let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { return false }
            return text.split(separator: "\n").count >= 3
        }
        XCTAssertTrue(wrote, "no session file with two lines")
        await m.leave()
        let f = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first)
        let lines = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("session v=1 "), "\(lines[0])")
        XCTAssertTrue(lines[1].hasPrefix("t_s=1 "), "\(lines[1])")
        for key in ["mac_fps=", "rtt_ms=", "thermal="] { XCTAssertTrue(lines[1].contains(key), "\(lines[1])") }
    }

    /// One second without numbers does not end the recording; only the end of the play does. The header carries the
    /// display rate set after the play began.
    func testRecordingSurvivesASecondWithoutNumbers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (m, p) = try await paired(recordings: dir)
        try await play(m, p)
        m.displayMaxHz = 120  // the view reports it after the play started
        let l = try XCTUnwrap(m.link)
        let got = await waitFor(4) { m.stats != nil && m.playStats != nil }
        XCTAssertTrue(got)
        let (s, ps) = (m.stats, m.playStats)
        m.stats = nil; m.playStats = nil
        XCTAssertEqual(m.recordLine(link: l, sinceNs: 0), .none)
        m.stats = s; m.playStats = ps
        if case .line = m.recordLine(link: l, sinceNs: 0) {} else { XCTFail("numbers back, no line") }
        let wrote = await waitFor(6) {
            guard let f = try? FileManager.default.contentsOfDirectory(atPath: dir.path).first,
                  let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { return false }
            return text.split(separator: "\n").count >= 3
        }
        XCTAssertTrue(wrote)
        let f = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first)
        let header = try XCTUnwrap(String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8).split(separator: "\n").first)
        XCTAssertTrue(header.contains("display_max_hz=120"), "\(header)")
        await m.leave()
        XCTAssertEqual(m.recordLine(link: l, sinceNs: 0), .over)
    }

    // MARK: live settings (network 4)

    private func waitLive(_ timeout: TimeInterval = 5, _ cond: @escaping (LiveSettings?) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(await service.liveSettings()) { return true }
            await sleep(0.01)
        }
        return cond(await service.liveSettings())
    }

    /// `applyLive()` sends the ceiling and the panel level; the Host records both and the session's rate follows the ceiling.
    func testApplyLiveReachesTheHostAndTheRateController() async throws {
        let (m, _) = try await paired()
        var s = m.settings
        s.bitrateMbps = 80; s.statsLevel = .full
        m.settings = s
        m.applyLive()
        let there = await waitLive { $0 == LiveSettings(ceilingBps: 80_000_000, panel: .full) }
        let seen = await service.liveSettings()
        XCTAssertTrue(there, "host has \(String(describing: seen))")
        let ceiling = await m.session?.stats().rateCeilingBps
        XCTAssertEqual(ceiling, 80_000_000)
        m.settings.bitrateMbps = 20
        m.applyLive()
        let lowered = await waitLive { $0?.ceilingBps == 20_000_000 }
        XCTAssertTrue(lowered)
        let rate = await m.session?.currentRate
        XCTAssertLessThanOrEqual(rate ?? .max, 20_000_000, "a lowered ceiling cuts the rate at once")
        m.settings.statsLevel = .off
        m.applyLive()
        let off = await waitLive { $0 == LiveSettings(ceilingBps: 20_000_000, panel: .off) }
        XCTAssertTrue(off)
    }

    /// One floor on both sides: the client never sends a ceiling under the rate controller's floor (the larger of the two
    /// floors, the client's 2 Mbit/s, wins over the Host's 1 Mbit/s).
    func testTheLiveCeilingIsNeverUnderTheRateFloor() async throws {
        let (m, _) = try await paired()
        m.settings.bitrateMbps = 1
        XCTAssertEqual(m.liveNow.ceilingBps, RateController.floorBps)
        m.settings.bitrateMbps = 0
        XCTAssertEqual(m.liveNow.ceilingBps, RateController.floorBps)
        m.settings.bitrateMbps = 50
        XCTAssertEqual(m.liveNow.ceilingBps, 50_000_000)
    }

    /// The `hello` wish uses the same floor as the live ceiling (a hand-edited 1 Mbit/s is floored before it is sent).
    func testTheHelloBitrateUsesTheSameFloorAsTheLiveCeiling() async throws {
        let (m, _) = try await paired()
        let expected: [(mbps: Int, bps: UInt32)] = [(0, RateController.floorBps), (1, RateController.floorBps), (2, 2_000_000),
                                                    (50, 50_000_000), (5_000, 1_000_000_000)]
        for (mbps, bps) in expected {
            m.settings.bitrateMbps = mbps
            XCTAssertEqual(m.helloBitrate, bps, "\(mbps) Mbit/s")
            XCTAssertEqual(m.liveNow.ceilingBps, bps, "the live ceiling is the same number")
        }
    }

    /// The session `makeSession` builds is the one that sends it: its `hello` wish is the floored number.
    func testTheSessionsHelloCarriesTheFlooredBitrate() async throws {
        let (m, _) = try await paired()
        m.settings.bitrateMbps = 1
        let low = try m.makeSession()
        let lowBps = await low.bitrate
        XCTAssertEqual(lowBps, RateController.floorBps)
        m.settings.bitrateMbps = 50
        let normal = try m.makeSession()
        let normalBps = await normal.bitrate
        XCTAssertEqual(normalBps, 50_000_000)
        await low.close()
        await normal.close()
    }

    /// The session itself ends (not only the controller's input) while the menu is open and A is held: the screen leaves play
    /// (the view, and with it the menu, goes), the game is left with no button down, and a late press reaches nothing.
    func testTheSessionEndingUnderTheOpenMenuLeavesNoInputStuck() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        let controller = ControllerInput(settings: m.settings) { input in MainActor.assumeIsolated { m.send(input) } }
        controller.start()
        var a = PadSnapshot(); a.buttonA = true
        controller.padArrived(a, from: nil); controller.drainNow()
        let game = try XCTUnwrap(launcher.game)
        func pads() -> [UInt64] {
            game.received.compactMap { if case let .pad(0, buttons, _, _, _, _) = $0 { buttons } else { nil } }
        }
        let held = await waitFor { pads().last.map { $0 != 0 } == true }
        XCTAssertTrue(held, "A reached the game: \(pads())")
        controller.menuOpen = true  // the menu opens with A still down; the session then ends under it
        await m.leave()
        XCTAssertNotEqual(m.screen, .playing, "the play view, and the menu in it, are gone")
        controller.stop()  // the view's onDisappear
        let released = await waitFor { pads().last == 0 }
        XCTAssertTrue(released, "the game is left with a button down: \(pads())")
        let after = pads().count
        controller.padArrived(a, from: nil); controller.drainNow()
        m.send(InputState(seq: 1, player: 0, buttons: 1, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(pads().dropFirst(after).allSatisfy { $0 == 0 }, "a late press after the session ended reached the game: \(pads())")
        XCTAssertEqual(pads().last, 0)
    }

    /// C9: a fresh session tells the Host the saved ceiling and panel level, with no menu action; so does a reconnect.
    func testAFreshSessionAndAReconnectSendTheSavedLiveSettings() async throws {
        var saved = ClientSettings()
        saved.statsLevel = .full; saved.bitrateMbps = 30
        let want = LiveSettings(ceilingBps: 30_000_000, panel: .full)
        let (m, _) = try await paired(settings: saved)
        let first = await waitLive { $0 == want }
        let seenFirst = await service.liveSettings()
        XCTAssertTrue(first, "fresh session: \(String(describing: seenFirst))")
        await m.background()
        let gone = await waitLive { $0 == nil }
        XCTAssertTrue(gone, "the Host's session is over")
        await m.foreground()
        let again = await waitLive { $0 == want }
        let seenAgain = await service.liveSettings()
        XCTAssertTrue(again, "after the reconnect: \(String(describing: seenAgain))")
    }

    /// "Apply and reconnect" keeps the game: the same instance runs on, the new size and frame rate are in the next hello.
    func testReconnectApplyingKeepsTheSameGameAndClearsThePendingFlag() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        XCTAssertFalse(m.pendingReconnect)
        m.settings.maxFps = 30
        XCTAssertTrue(m.pendingReconnect, "a frame rate change needs a new connection")
        m.settings.maxFps = 60
        XCTAssertFalse(m.pendingReconnect, "back to what the connection has")
        m.settings.maxWidth = 1280; m.settings.maxHeight = 720
        XCTAssertTrue(m.pendingReconnect)
        m.settings.bitrateMbps = 20
        let shown = p.count
        await m.reconnectApplying()
        let back = await waitFor(8) { m.screen == .playing && m.gameState?.run == .running && p.count >= shown + 5 }
        XCTAssertTrue(back, "screen \(m.screen), state \(String(describing: m.gameState)), message \(m.message ?? "-")")
        XCTAssertEqual(m.gameState?.titleID, fakeID)
        XCTAssertFalse(m.pendingReconnect)
        XCTAssertTrue(launcher.game === game, "the same game instance, not a new launch")
        XCTAssertEqual(game.received.filter { $0 == .pause(true) }.count, 1, "paused once while the device was away")
    }

    /// With nothing open or nothing changed, reconnecting does no harm.
    func testReconnectApplyingWithoutASessionDoesNothing() async throws {
        let (m, _) = model()
        await m.reconnectApplying()
        XCTAssertFalse(m.pendingReconnect)
        XCTAssertNotEqual(m.screen, .playing)
    }

    /// C11: `playSound` off keeps the session's sound gate shut; it follows the setting while the session runs.
    func testPlaySoundFollowsTheSettingInARunningSession() async throws {
        var quiet = ClientSettings(); quiet.playSound = false
        let (m, _) = try await paired(settings: quiet)
        XCTAssertEqual(m.link?.gate.soundOn, false)
        m.settings.playSound = true
        XCTAssertEqual(m.link?.gate.soundOn, true)
        m.settings.playSound = false
        XCTAssertEqual(m.link?.gate.soundOn, false)
    }

    func testPlayStats() async throws {
        let (m, p) = try await paired()
        XCTAssertNil(m.playStats)
        try await play(m, p)
        let got = await waitFor(4) { (m.playStats?.macFps ?? 0) > 0 && (m.playStats?.rttMs ?? 0) > 0 && (m.playStats?.decodeMs ?? 0) > 0 }
        let st = try XCTUnwrap(m.playStats)
        XCTAssertTrue(got, "no full snapshot: \(st)")
        XCTAssertTrue((50...70).contains(st.macFps), "macFps \(st.macFps)")
        XCTAssertGreaterThan(st.bitrateMbps, 0)
        XCTAssertEqual(st.width, 1280); XCTAssertEqual(st.height, 720)
        XCTAssertTrue((0..<50).contains(st.rttMs), "rtt \(st.rttMs)")
        XCTAssertGreaterThan(st.decodeMs, 0)
        let hosted = await waitFor(3) { m.playStats?.host != nil }
        XCTAssertTrue(hosted, "no hostStats in the play stats")
        m.displayCounts(shown: 58, late: 2, empty: 2, seconds: 1)
        let counted = await waitFor(2) { m.playStats?.shownFps == 58 }
        XCTAssertTrue(counted, "shownFps \(m.playStats?.shownFps ?? -1)")
        XCTAssertEqual(m.playStats?.late, 2)
        XCTAssertEqual(m.latePictures, 2)
        await m.leave()
        XCTAssertNil(m.playStats)
    }

    /// At "full" the Host's load reaches the play stats as the Host sent it; below "full" there is none.
    func testPlayStatsCarryTheHostsLoadOnlyAtFull() async throws {
        let (m, p) = try await paired()
        m.settings.statsLevel = .compact
        try await play(m, p)
        await sleep(1.6)
        XCTAssertNil(m.playStats?.load, "nothing is sent below full")
        m.settings.statsLevel = .full
        m.applyLive()
        let got = await waitFor(4) { m.playStats?.load != nil }
        XCTAssertTrue(got, "no load in the play stats")
        let l = try XCTUnwrap(m.playStats?.load)
        XCTAssertEqual(l.cpuTotal, 412); XCTAssertEqual(l.gpu, 783); XCTAssertTrue(l.gpuPresent)
        XCTAssertEqual(l.memTotalMiB, 32_768); XCTAssertEqual(l.gameCpuCentiCores, 160)
        let newest = await m.session?.stats().load
        XCTAssertEqual(l.cpuTotal, newest?.cpuTotal, "the newest the Host sent")
        let lines = PanelText.lines(level: .full, stats: m.playStats, pacing: .smooth)
        XCTAssertTrue(lines[8].contains("CPU 41 %"), lines[8])
        m.settings.statsLevel = .compact
        m.applyLive()
        let stale = await waitFor(6) { m.playStats?.load == nil }
        XCTAssertTrue(stale, "the numbers go when the Host stops sending them")
    }

    /// The decode pump alone: shut gate -> dropped; not decodable -> a key frame is asked for and nothing is shown.
    func testDecodeAsksForKeyAndGateDrops() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var out: [(Bool, UInt64, Data)] = []
        let enc = try XCTUnwrap(FakeEncoder(width: 320, height: 180, fps: 60, bitrate: 1_000_000) { o in
            lock.withLock { out.append((o.key, o.captureNs, o.data ?? Data())) }
        })
        for i in 0..<6 { enc.encode(color: 0xFF00_0000 | UInt32(i * 40), request: .init(key: i == 0 || i == 3), captureNs: UInt64(i) * 16_000) }
        enc.finish()
        let encoded = lock.withLock { out }
        XCTAssertEqual(encoded.map(\.0), [true, false, false, true, false, false])
        let frames = encoded.enumerated().map { i, f in
            AssembledFrame(frame: UInt32(i), key: f.0, captureNs: f.1, width: 320, height: 180, data: f.2)
        }

        let gate = PlayGate(), sink = PictureSink(), asked = Counter(), pictures = Pictures()
        sink.handler = { pictures.add($0) }
        let decoder = VideoDecoder()

        // Gate shut: everything is dropped, nothing decoded, nothing asked.
        let (shut, feedShut) = AsyncStream.makeStream(of: AssembledFrame.self)
        for f in frames { feedShut.yield(f) }
        feedShut.finish()
        await ClientModel.decode(shut, decoder, gate, sink) { _ in asked.bump() }
        XCTAssertEqual(asked.value, 0)
        XCTAssertEqual(pictures.count, 0)

        let (stream, feed) = AsyncStream.makeStream(of: AssembledFrame.self)
        let pump = Task { await ClientModel.decode(stream, decoder, gate, sink) { _ in asked.bump() } }
        gate.isOpen = true
        feed.yield(frames[1])  // a delta with nothing decoded before it
        feed.yield(frames[2])
        let askedTwice = await waitFor { asked.value == 2 }
        XCTAssertTrue(askedTwice, "asked \(asked.value), pictures \(pictures.count)")
        XCTAssertEqual(pictures.count, 0)
        for f in frames[3...] { feed.yield(f) }
        let shown = await waitFor { pictures.count == 3 }
        XCTAssertTrue(shown, "pictures \(pictures.all.map(\.frame))")
        XCTAssertEqual(pictures.all.map(\.frame), [3, 4, 5])
        XCTAssertEqual(asked.value, 2)
        feed.finish()
        await pump.value
    }

    /// The device goes away (the old leave: no session); choosing the Mac again opens a library session: the game stays
    /// paused until the person chooses it, then resumes from a key frame.
    func testChoosingTheMacAgainShowsThePausedGameAndChoosingItResumes() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        await m.disconnect()
        XCTAssertEqual(m.screen, .library, "a paired Mac exists: the library, not the first-run screen")
        XCTAssertEqual(m.macState, .unreachable)
        XCTAssertTrue(m.games.isEmpty)
        XCTAssertNil(m.gameState)
        let paused = await pausedOnHost()
        XCTAssertTrue(paused, "the Host did not pause the game")
        let before = p.count
        await m.choose(found)
        let library = await waitFor { m.macState == .connected && m.games.first { $0.titleID == self.fakeID }?.state == .paused }
        XCTAssertTrue(library, "games \(m.games), state \(m.macState)")
        await sleep(0.5)  // a negative: choosing the Mac does not resume the game
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(p.count, before, "pictures in the library")
        XCTAssertFalse(launcher.game?.received.contains(.pause(false)) == true, "choosing the Mac resumed the game")
        await m.resume()
        let again = await waitFor { m.screen == .playing && p.count >= before + 5 }
        XCTAssertTrue(again, "screen \(m.screen), pictures \(p.count - before)")
        let next = p.all.dropFirst(before).first
        XCTAssertTrue(next.map { isKey($0.frame) } == true, "first picture after choosing again is not a key frame")
    }

    /// "Disconnect" in play: a live library of the same Mac, the game listed as paused, no sentence; the game got one
    /// pause and no resume; choosing the game resumes into play.
    func testLeaveFromPlayReturnsToALiveLibraryAndChoosingTheGameResumes() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        await m.leave()
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .connected)
        XCTAssertNil(m.message)
        XCTAssertNil(m.problem)
        let listed = await waitFor { m.games.first { $0.titleID == self.fakeID }?.state == .paused }
        XCTAssertTrue(listed, "games \(m.games)")
        XCTAssertEqual(m.gameState?.run, .paused)
        let before = p.count
        await sleep(0.5)  // a negative: the library session resumes nothing
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(p.count, before, "pictures in the library")
        XCTAssertEqual(game.received.filter { $0 == .pause(true) }.count, 1, "\(game.received.suffix(6))")
        XCTAssertFalse(game.received.contains(.pause(false)), "\(game.received.suffix(6))")
        await m.resume()
        let again = await waitFor { m.screen == .playing && p.count >= before + 5 }
        XCTAssertTrue(again, "screen \(m.screen), pictures \(p.count - before)")
    }

    /// A reachable library with a preparing game: the tile reads "Preparing <n> %" and the number follows the Host's progress;
    /// on an unreachable list it is greyed, never live.
    func testTheTileFollowsTheProgressInAReachableLibraryAndIsNeverLiveWhenUnreachable() async throws {
        try await restartService(launcher: FakeLauncher(stall: 4))
        let (m, _) = try await paired()
        await m.launch(fakeEntry)
        _ = await waitFor { m.screen == .playing && (m.preparing?.total ?? 0) > 0 }
        await m.leave()
        func tile() -> LibraryText.TileState? {
            m.games.first { $0.titleID == self.fakeID }.map {
                LibraryText.tileState($0, reachable: m.macState == .connected, preparing: m.preparing(for: self.fakeID))
            }
        }
        var seen: [Int] = []
        let advanced = await waitFor(6) {
            if case .preparing(let percent?)? = tile(), seen.last != percent { seen.append(percent) }
            return seen.count >= 2
        }
        XCTAssertTrue(advanced, "the tile's percent did not move: \(seen)")
        XCTAssertEqual(seen, seen.sorted(), "the percent went backward")
        XCTAssertEqual(m.screen, .library)
        if let entry = m.games.first(where: { $0.titleID == fakeID }) {
            XCTAssertEqual(LibraryText.tileState(entry, reachable: false, preparing: .init(phase: 1, done: 5, total: 10)), .unreachable)
        }
    }

    /// "Back to games" while the game prepares: a live library whose tile follows the Mac's progress; the screen never
    /// changes by itself; choosing the game returns to the starting screen and no pause reaches the game.
    func testLeaveWhilePreparingShowsTheLiveProgressAndChoosingTheGameReturns() async throws {
        try await restartService(launcher: FakeLauncher(stall: 4))
        let (m, p) = try await paired()
        await m.launch(fakeEntry)
        let preparing = await waitFor { m.screen == .playing && (m.preparing?.total ?? 0) > 0 }
        XCTAssertTrue(preparing, "screen \(m.screen), preparing \(String(describing: m.preparing))")
        await m.leave()
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .connected)
        XCTAssertNil(m.message)
        var screens: Set<String> = []
        let seen = await waitFor { screens.insert("\(m.screen)"); return (m.preparing(for: self.fakeID)?.total ?? 0) > 0 }
        XCTAssertTrue(seen, "no live progress in the library: \(String(describing: m.gameState))")
        let first = try XCTUnwrap(m.preparing(for: fakeID)).done
        let rose = await waitFor(3) { screens.insert("\(m.screen)"); return (m.preparing(for: self.fakeID)?.done ?? 0) > first }
        XCTAssertTrue(rose, "the progress did not move: \(first) -> \(String(describing: m.preparing(for: fakeID)))")
        XCTAssertEqual(screens, ["library"], "the screen changed by itself")
        let entry = try XCTUnwrap(m.games.first { $0.titleID == fakeID })
        guard case .preparing(let percent?) = LibraryText.tileState(entry, reachable: m.macState == .connected,
                                                                   preparing: m.preparing(for: fakeID)) else {
            return XCTFail("the tile shows no percent: \(entry), \(String(describing: m.preparing(for: fakeID)))")
        }
        XCTAssertGreaterThan(percent, 0)
        XCTAssertNotEqual(entry.state, .idle, "the view resumes a listed running game")
        await m.resume()
        let starting = await waitFor { m.screen == .playing }
        XCTAssertTrue(starting, "screen \(m.screen)")
        XCTAssertNotNil(m.preparing, "the starting screen shows the preparation")
        let pictures = await waitFor(6) { p.count >= 5 }
        XCTAssertTrue(pictures, "pictures \(p.count)")
        await sleep(0.3)
        XCTAssertFalse(launcher.game?.received.contains(.pause(true)) == true, "paused at the first picture")
        XCTAssertEqual(m.screen, .playing)
    }

    /// A connection lost during play still reconnects into play (a resuming session), as before.
    func testALostConnectionDuringPlayReconnectsIntoPlay() async throws {
        let (m, p) = try await paired(retry: 0.2, silence: 1)
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let lost = await waitFor(4) { m.reconnecting }
        XCTAssertTrue(lost)
        let before = p.count
        let back = await waitFor(6) { !m.reconnecting && m.screen == .playing && p.count >= before + 5 }
        XCTAssertTrue(back, "reconnecting \(m.reconnecting), screen \(m.screen), pictures \(p.count - before)")
        XCTAssertFalse(m.session === session)
        if let pause = game.received.lastIndex(of: .pause(true)) {
            XCTAssertTrue(game.received[pause...].contains(.pause(false)), "paused and never resumed: \(game.received.suffix(6))")
        }
    }

    /// A fresh start on a store whose Mac has this device's game paused: the library with the game, not play.
    func testAFreshStartWithAPausedGameShowsTheLibrary() async throws {
        let secrets = MemorySecrets()
        let (first, p1) = try await paired(secrets)
        try await play(first, p1)
        await first.disconnect()
        let paused = await pausedOnHost()
        XCTAssertTrue(paused)
        let (m, p) = model(secrets)
        let library = await waitFor { m.macState == .connected && m.games.first { $0.titleID == self.fakeID }?.state == .paused }
        XCTAssertTrue(library, "state \(m.macState), games \(m.games), message \(m.message ?? "-")")
        await sleep(0.5)  // a negative: no resume at launch
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(p.count, 0)
        XCTAssertFalse(launcher.game?.received.contains(.pause(false)) == true)
        XCTAssertEqual(m.continueGame?.state, .paused)
    }

    /// `leave()` when the Mac is gone: unreachable, with "Cannot reach ...".
    func testLeaveWhenTheMacIsGoneIsUnreachable() async throws {
        let (m, p) = try await paired(retry: 30)
        try await play(m, p)
        await service.stop()
        await m.leave()
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .unreachable)
        XCTAssertEqual(m.message, Messages.cannotReach(hostName))
        XCTAssertFalse(m.reconnecting)
    }

    // MARK: play is what the Host confirmed (`playChosen`)

    /// The game the session played is gone (a quit): the session is a library one again, so a background and foreground
    /// reopens a library session (the Host would otherwise count the idle library as playing).
    func testAfterAQuitABackgroundReopensALibrarySession() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        XCTAssertTrue(m.playChosen)
        await m.quitGame()
        let idle = await waitFor(6) { m.screen == .library && m.games.first?.state == .idle }
        XCTAssertTrue(idle, "screen \(m.screen), games \(m.games)")
        XCTAssertFalse(m.playChosen, "the play is over")
        await m.background()
        await m.foreground()
        let back = await waitFor { m.macState == .connected }
        XCTAssertTrue(back)
        XCTAssertFalse(m.playChosen, "reopened resuming")
        XCTAssertEqual(m.screen, .library)
    }

    /// A stale tile asks to resume a game the Mac no longer has: the Host answers idle, so the ask is over (nothing is left
    /// to confirm a later state as this play) and the screen stays on the library.
    func testAResumeAnsweredIdleClearsTheAsk() async throws {
        let (m, _) = try await paired()
        let connected = await waitFor { m.macState == .connected && m.gameState != nil }
        XCTAssertTrue(connected)
        await m.resume()
        let answered = await waitFor(3) { m.playAsked == nil }
        XCTAssertTrue(answered, "the idle answer left the ask set: \(m.playAsked ?? "-")")
        XCTAssertFalse(m.playChosen)
        XCTAssertEqual(m.screen, .library)
    }

    /// A launch whose session died before the answer: the next session starts with no note of it.
    func testANewSessionForgetsALaunchAskedOnTheOldOne() async throws {
        let (m, _) = try await paired()
        let connected = await waitFor { m.macState == .connected }
        XCTAssertTrue(connected)
        m.launchAsked = "STALE00000000000"
        await m.background()
        await m.foreground()
        let back = await waitFor { m.macState == .connected }
        XCTAssertTrue(back)
        XCTAssertNil(m.launchAsked, "the old session's ask would label this session's first reason")
    }

    /// A launch note that never got its answer does not relabel a later crash.
    func testAStaleLaunchNoteDoesNotRelabelACrash() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        m.launchAsked = "STALE00000000000"
        m.playAsked = "STALE00000000000"
        launcher.game?.stop(exitCode: 3)
        let library = await waitFor { m.screen == .library }
        XCTAssertTrue(library, "screen \(m.screen)")
        XCTAssertTrue(m.message?.hasPrefix("The game ended") == true, "message \(m.message ?? "-")")
        XCTAssertNil(m.launchAsked)
        XCTAssertNil(m.playAsked)
        XCTAssertFalse(m.playChosen)
    }

    /// A paused game X; a launch of Y is refused ("X is running"): the session stays a library one, so coming back from
    /// the background reopens a library session and X stays paused.
    func testARefusedLaunchLeavesALibrarySessionAcrossABackground() async throws {
        _ = try await serveArtGame()
        let (m, p) = try await paired()
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        await m.leave()
        let listed = await waitFor { m.macState == .connected && m.games.first { $0.titleID == self.fakeID }?.state == .paused }
        XCTAssertTrue(listed)
        let other = try XCTUnwrap(m.games.first { $0.titleID == artID })
        await m.launch(other)
        let said = await waitFor { m.message == "Fake Game is running." }
        XCTAssertTrue(said, "message \(m.message ?? "-")")
        await m.background()
        await m.foreground()
        let back = await waitFor { m.macState == .connected }
        XCTAssertTrue(back)
        await sleep(0.5)  // a negative: nothing resumes
        XCTAssertEqual(m.screen, .library)
        XCTAssertFalse(game.received.contains(.pause(false)), "the game was resumed: \(game.received.suffix(6))")
        XCTAssertEqual(m.games.first { $0.titleID == fakeID }?.state, .paused)
    }

    /// The same with a lost connection: the retry loop reopens a library session.
    func testARefusedLaunchLeavesALibrarySessionAcrossALostConnection() async throws {
        _ = try await serveArtGame()
        let (m, p) = try await paired(retry: 0.2, silence: 1)
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        await m.leave()
        _ = await waitFor { m.macState == .connected && m.games.first { $0.titleID == self.fakeID }?.state == .paused }
        let other = try XCTUnwrap(m.games.first { $0.titleID == artID })
        await m.launch(other)
        _ = await waitFor { m.message == "Fake Game is running." }
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let lost = await waitFor(4) { m.reconnecting }
        XCTAssertTrue(lost)
        let back = await waitFor(6) { !m.reconnecting && m.macState == .connected && !(m.session === session) }
        XCTAssertTrue(back, "reconnecting \(m.reconnecting), state \(m.macState)")
        await sleep(0.5)  // a negative: nothing resumes
        XCTAssertEqual(m.screen, .library)
        XCTAssertFalse(game.received.contains(.pause(false)), "the game was resumed: \(game.received.suffix(6))")
    }

    /// X prepares in a live library; a launch of Y is answered with X running: the screen stays on the library with the
    /// Host's sentence.
    func testALaunchRedirectedByAPreparingGameStaysOnTheLibrary() async throws {
        launcher = FakeLauncher(stall: 4)
        _ = try await serveArtGame()
        let (m, _) = try await paired()
        await m.launch(fakeEntry)
        _ = await waitFor { m.screen == .playing && m.preparing != nil }
        await m.leave()
        _ = await waitFor { m.macState == .connected && m.preparing(for: self.fakeID) != nil }
        let other = try XCTUnwrap(m.games.first { $0.titleID == artID })
        var screens: Set<String> = []
        await m.launch(other)
        let said = await waitFor { screens.insert("\(m.screen)"); return m.message == "Fake Game is running." }
        XCTAssertTrue(said, "message \(m.message ?? "-")")
        _ = await waitFor(1) { screens.insert("\(m.screen)"); return false }
        XCTAssertEqual(screens, ["library"])
        XCTAssertNil(m.macRows.first { $0.current }?.playing, "the Macs list says nothing is playing here")
    }

    /// `leave()`, then a background before the library connect completes, then `foreground()`: the game stays paused.
    func testABackgroundDuringTheLeaveConnectDoesNotResume() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        let leaving = Task { await m.leave() }
        for _ in 0..<1000 where m.macState != .connecting { await Task.yield() }  // up to leave()'s first wait, not past it
        XCTAssertEqual(m.macState, .connecting)
        await m.background()
        await leaving.value
        await m.foreground()
        let back = await waitFor { m.macState == .connected && m.link != nil }
        XCTAssertTrue(back, "state \(m.macState)")
        await sleep(0.5)  // a negative: nothing resumes
        XCTAssertEqual(m.screen, .library)
        XCTAssertFalse(game.received.contains(.pause(false)), "the game was resumed: \(game.received.suffix(6))")
    }

    // MARK: a library session gives way to another device

    /// Device 2 sits in the library; Device 1 connects and takes the Mac. Device 2 shows the last known games with
    /// "<Mac> is now in use on Device 1." and makes no attempt of its own until Retry.
    func testALibrarySessionGivesWayAndDoesNotTakeTheMacBack() async throws {
        let (m2, _) = try await paired(name: "Device 2", retry: 0.2, cache: LibraryCache(directory: dir.appendingPathComponent("libraries")))
        let (m1, _) = try await paired(name: "Device 1")
        XCTAssertEqual(m1.macState, .connected)
        let told = await waitFor { m2.macState == .unreachable && m2.message == Messages.sentence(.inUse(device: "Device 1"), mac: self.hostName) }
        XCTAssertTrue(told, "state \(m2.macState), message \(m2.message ?? "-")")
        XCTAssertEqual(m2.screen, .library)
        XCTAssertEqual(m2.problem, .inUse(device: "Device 1"))
        XCTAssertFalse(m2.games.isEmpty, "the last known games")
        await sleep(1.5)  // a negative: no attempt of its own
        XCTAssertNil(m2.session)
        XCTAssertFalse(m2.reconnecting)
        XCTAssertEqual(m1.macState, .connected, "the Mac was taken back")
        XCTAssertNotNil(m1.session)
        await m2.retry()
        let again = await waitFor { m2.macState == .connected }
        XCTAssertTrue(again, "Retry takes the Mac back from a library session: \(m2.message ?? "-")")
    }

    func testOtherDeviceSeesResume() async throws {
        let (m1, p1) = try await paired(name: "Device 1")
        try await play(m1, p1)
        await m1.leave()
        let paused = await pausedOnHost()
        XCTAssertTrue(paused)
        let (m2, p2) = try await paired(name: "Device 2")
        XCTAssertEqual(m2.screen, .library)
        XCTAssertEqual(m2.games.first { $0.titleID == fakeID }?.state, .paused)
        await sleep(0.5)
        XCTAssertEqual(p2.count, 0, "pictures while paused")
        await m2.resume()
        let playing = await waitFor { m2.screen == .playing && p2.count >= 5 }
        XCTAssertTrue(playing, "screen \(m2.screen), pictures \(p2.count)")
    }

    func testQuitReturnsToLibrary() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        await m.quitGame()
        let library = await waitFor(6) { m.screen == .library && m.games.first?.state == .idle }
        XCTAssertTrue(library, "screen \(m.screen), games \(m.games)")
        XCTAssertNil(m.message)
    }

    /// I-1: one session, two games; the second numbers its frames from 0 again.
    func testSecondGameInOneSessionShowsPictures() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        // Well past 3 s of frames: an old assembler would drop the second game's first 3 s as old.
        let many = await waitFor(8) { p.count >= 240 }
        XCTAssertTrue(many, "pictures \(p.count)")
        await m.quitGame()
        let library = await waitFor(6) { m.screen == .library && m.games.first?.state == .idle }
        XCTAssertTrue(library, "screen \(m.screen), games \(m.games)")
        let session = try XCTUnwrap(m.session)
        let skippedBefore = await session.stats().framesSkipped
        let before = p.count
        await m.launch(fakeEntry)
        let again = await waitFor(3) { m.screen == .playing && p.count >= before + 5 }
        XCTAssertTrue(again, "screen \(m.screen), \(p.count - before) pictures after the second launch")
        XCTAssertTrue(m.session === session, "the session was replaced")
        let skippedAfter = await session.stats().framesSkipped
        XCTAssertLessThanOrEqual(skippedAfter - skippedBefore, 1, "the restart counted as skipped frames")
    }

    func testGameCrashSaysWhy() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        launcher.game?.stop(exitCode: 3)
        let library = await waitFor { m.screen == .library }
        XCTAssertTrue(library, "screen \(m.screen)")
        XCTAssertTrue(m.message?.hasPrefix("The game ended") == true, "message \(m.message ?? "-")")
    }

    func testBusyIsShown() async throws {
        let (m2, _) = try await paired(name: "Device 2")
        await m2.leave()
        let (m1, p1) = try await paired(name: "Device 1")
        try await play(m1, p1)
        await m2.choose(found)
        XCTAssertEqual(m2.message, "Test Host is playing on Device 1.")
        XCTAssertEqual(m2.screen, .library)
        XCTAssertEqual(m2.macState, .unreachable)
        XCTAssertEqual(m1.screen, .playing)
    }

    // MARK: Review focus

    func testBackgroundForegroundResumes() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        await m.background()
        let paused = await pausedOnHost()
        XCTAssertTrue(paused, "the Host did not pause the game")
        XCTAssertEqual(m.screen, .playing, "background() changed the screen")
        let before = p.count
        await m.foreground()
        let again = await waitFor { m.screen == .playing && p.count >= before + 5 }
        XCTAssertTrue(again, "screen \(m.screen), pictures \(p.count - before)")
        XCTAssertNil(m.message)
    }

    func testHostRestartReconnects() async throws {
        let (m, p) = try await paired(retry: 0.2, silence: 0.5)
        try await play(m, p)
        await service.stop()
        let lost = await waitFor(2) { m.reconnecting && m.message == Messages.connectionLost }
        XCTAssertTrue(lost, "reconnecting \(m.reconnecting), message \(m.message ?? "-")")
        service = try makeService(port: port)
        _ = try await service.start()
        let back = await waitFor(3) { !m.reconnecting && m.screen == .library }
        XCTAssertTrue(back, "reconnecting \(m.reconnecting), screen \(m.screen), message \(m.message ?? "-")")
        // The restarted Host has no game: playing -> idle that this device did not ask for.
        XCTAssertEqual(m.message, Messages.ended(reason: nil))
        XCTAssertTrue(m.games.contains { $0.titleID == fakeID })
    }

    func testGivenUpFramesAskForARestartPoint() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        let streaming = await waitFor { p.count >= 30 }
        XCTAssertTrue(streaming)
        let session = try XCTUnwrap(m.session)
        let startStats = await session.stats()
        let start = startStats.keyRequests + startStats.repairRequests
        let drop = DropAll()
        await session.setIncomingDatagramFilter { drop.keep($0) }
        // A lost datagram is asked for again (`nack`); 0.3 s of nothing is more than the window of 8 frames, so the
        // frames before it are given up and the session asks for a restart point: a repair frame once a key frame
        // has decoded (the fake game keeps long-term references), else a key frame -> .claude/client.md § repair
        drop.set(true)
        await sleep(0.3)
        drop.set(false)
        var asked = false
        for _ in 0..<100 where !asked {
            let s = await session.stats()
            asked = s.keyRequests + s.repairRequests > start
            if !asked { await sleep(0.01) }
        }
        XCTAssertTrue(asked, "no repair or key request after the frames were given up")
        let before = p.count
        let more = await waitFor { p.count >= before + 30 }
        XCTAssertTrue(more, "pictures stopped")
        let shown = p.all
        for (a, b) in zip(shown, shown.dropFirst()) where b.frame != a.frame + 1 {
            XCTAssertTrue(isRestart(b.frame), "picture \(b.frame) after \(a.frame) is neither a key nor a repair frame")
        }
        XCTAssertTrue(zip(shown, shown.dropFirst()).contains { $1.frame != $0.frame + 1 }, "no gap: the loss was not observed")
    }

    // MARK: fix round 1

    private func pads(_ game: FakeGame) -> [(buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32)] {
        game.received.compactMap { if case let .pad(0, b, lx, ly, rx, ry) = $0 { return (b, lx, ly, rx, ry) }; return nil }
    }

    /// A Host quiet for 2 s of a 3 s limit: `stalled` shows after about 1 s, the screen stays, input goes neutral (the
    /// session re-sends it), and the first thing from the Host clears it, brings the pictures back and lets input through.
    func testAStallIsShownInputGoesNeutralAndRecoveryClearsIt() async throws {
        let (m, p) = try await paired(silence: 3)
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        let session = try XCTUnwrap(m.session)
        let a = InputState(seq: 0, player: 0, buttons: PadButtons.a.rawValue, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil)
        m.send(a)
        let held = await waitFor(1) { self.pads(game).last?.buttons == PadButtons.a.rawValue }
        XCTAssertTrue(held)
        XCTAssertFalse(m.stalled)
        await session.setIncomingDatagramFilter { _ in false }
        let start = Date()
        let stalled = await waitFor(2) { m.stalled }
        XCTAssertTrue(stalled)
        XCTAssertTrue((0.9...1.7).contains(Date().timeIntervalSince(start)), "stalled after \(Date().timeIntervalSince(start)) s")
        let neutral = await waitFor(1) { self.pads(game).last?.buttons == 0 }
        XCTAssertTrue(neutral, "the held button stayed held through the stall")
        m.send(a)  // a press during the stall is not sent
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(pads(game).last?.buttons, 0, "input reached the game during the stall")
        XCTAssertEqual(m.screen, .playing)
        XCTAssertNil(m.message)
        let before = p.count
        await session.setIncomingDatagramFilter(nil)
        let cleared = await waitFor(2) { !m.stalled }
        XCTAssertTrue(cleared)
        let back = await waitFor(3) { p.count >= before + 5 }
        XCTAssertTrue(back, "no pictures after the stall")
        m.send(a)
        let pressed = await waitFor(1) { self.pads(game).last?.buttons == PadButtons.a.rawValue }
        XCTAssertTrue(pressed, "input did not come back")
        XCTAssertEqual(m.screen, .playing)
    }

    // MARK: connection trouble -> TroubleStage

    private final class FakeClock: @unchecked Sendable {  // main actor only in these tests
        var now = 100.0
    }

    /// The picture stops: the stall signal makes it a pill (1 s), the injected clock moves it to "reconnecting" (3 s), the
    /// session's end to the ended card (with the game paused on the Mac and the reconnect loop going on behind it).
    func testTroubleGoesPillThenReconnectingThenEnded() async throws {
        let (m, p) = try await paired(retry: 30, silence: 2)
        let clock = FakeClock()
        m.clock = { clock.now }
        try await play(m, p)
        XCTAssertEqual(m.trouble, .none)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let stalled = await waitFor(3) { m.stalled }
        XCTAssertTrue(stalled)
        XCTAssertEqual(m.trouble, .pill, "a second of silence is the pill")
        XCTAssertTrue(m.menuAllowed, "the pill takes nothing from the menu")
        clock.now += 1.9
        m.refreshTrouble()
        XCTAssertEqual(m.trouble, .pill, "2.9 s")
        clock.now += 0.1
        m.refreshTrouble()
        XCTAssertEqual(m.trouble, .reconnecting, "3 s")
        XCTAssertFalse(m.menuAllowed, "nothing opens the menu over the reconnecting screen")
        let ended = await waitFor(5) { if case .ended = m.trouble { true } else { false } }
        XCTAssertTrue(ended, "trouble \(m.trouble)")
        XCTAssertEqual(m.trouble, .ended(reason: Messages.sessionEnded(mac: hostName, game: "Fake Game")))
        XCTAssertEqual(m.screen, .playing, "the card lives over the play screen")
        XCTAssertFalse(m.menuAllowed, "nothing opens the menu over the ended card")
        XCTAssertTrue(m.reconnecting, "the transport's reconnect loop is not changed by the card")
    }

    /// The stage follows the stall: recovery clears it at once, and it never gets worse once the link is back.
    func testRecoveryClearsTheStageAtOnceAndItNeverComesBack() async throws {
        let (m, p) = try await paired(retry: 30, silence: 8)
        let clock = FakeClock()
        m.clock = { clock.now }
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let stalled = await waitFor(3) { m.stalled }
        XCTAssertTrue(stalled)
        clock.now += 1
        m.refreshTrouble()
        XCTAssertEqual(m.trouble, .pill, "2 s of silence")
        await session.setIncomingDatagramFilter(nil)
        let back = await waitFor(3) { !m.stalled }
        XCTAssertTrue(back)
        XCTAssertEqual(m.trouble, .none, "recovery clears the stage at once")
        clock.now += 10
        m.refreshTrouble()
        XCTAssertEqual(m.trouble, .none, "the stage got worse with the link back")
    }

    /// "Apply and reconnect" has no pictures by design until the game is back: no stage for it.
    func testReconnectApplyingNeverShowsTrouble() async throws {
        let (m, p) = try await paired()
        let clock = FakeClock()
        m.clock = { clock.now }
        try await play(m, p)
        await m.reconnectApplying()
        XCTAssertNotNil(m.session)
        for step in [0.0, 1.5, 5, 10] {
            clock.now += step
            m.refreshTrouble()
            XCTAssertEqual(m.trouble, .none, "\(step) s after the reconnect")
        }
    }

    /// A game that is starting or preparing shows no pictures by design: no stage however long it takes.
    func testAPreparingGameNeverShowsTrouble() async throws {
        try await restartService(launcher: FakeLauncher(stall: 3))
        let (m, _) = try await paired()
        let clock = FakeClock()
        m.clock = { clock.now }
        await m.launch(fakeEntry)
        let preparing = await waitFor { m.preparing != nil }
        XCTAssertTrue(preparing)
        clock.now += 10
        m.refreshTrouble()
        XCTAssertFalse(m.stalled)
        XCTAssertEqual(m.trouble, .none)
    }

    /// A stall while the person is in the menu: "Disconnect" (`leave()`) still works and the stage is gone after it.
    func testLeavingDuringAStallGivesALiveLibrary() async throws {
        let (m, p) = try await paired(retry: 30, silence: 8)
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let stalled = await waitFor(3) { m.stalled }
        XCTAssertTrue(stalled)
        XCTAssertEqual(m.trouble, .pill)
        await m.leave()
        XCTAssertEqual(m.trouble, .none)
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .connected)
    }

    /// "Reconnect" that finds nobody: the card stays, the retry loop runs (with a fresh window and a zero media-path count).
    func testReconnectOnTheEndedCardThatMissesKeepsTheCardAndTheLoop() async throws {
        let (m, p) = try await paired(retry: 30, silence: 1.5)
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let ended = await waitFor(6) { if case .ended = m.trouble { true } else { false } }
        XCTAssertTrue(ended)
        await service.stop()
        m.mediaPathFailures = 2
        await m.reconnectNow()
        if case .ended = m.trouble {} else { XCTFail("the card went: \(m.trouble)") }
        XCTAssertTrue(m.reconnecting, "no retry loop after a missed attempt")
        XCTAssertEqual(m.mediaPathFailures, 0, "a deliberate fresh attempt counts from zero")
        XCTAssertFalse(m.busy)
        XCTAssertEqual(m.screen, .playing)
    }

    /// The starting card: the game prepares, or it is starting and no picture of it has shown yet (the one condition the
    /// play screen draws it by and counts as a cover).
    func testTheStartingCardIsPreparingOrAStartWithNoPictureYet() {
        let (m, _) = model()
        XCTAssertFalse(m.startingCard)
        m.gameState = GameState(titleID: fakeID, run: .starting, reason: nil)
        XCTAssertTrue(m.startingCard)
        m.pictureShown = true
        XCTAssertFalse(m.startingCard, "the first picture ends the card")
        m.gameState = GameState(titleID: fakeID, run: .running, reason: nil)
        XCTAssertFalse(m.startingCard)
        m.preparing = .waiting
        XCTAssertTrue(m.startingCard, "a running game that prepares again shows it")
    }

    // MARK: play lost another way than its session ending: the ended card at once

    /// Back from the background to a Mac that is gone: the ended card with its reason and Reconnect, the loop under it.
    func testAFailedReturnFromTheBackgroundDuringPlayEndsOnTheCard() async throws {
        let (m, p) = try await paired(retry: 30)
        try await play(m, p)
        await service.stop()
        await m.background()
        await m.foreground()
        XCTAssertEqual(m.trouble, .ended(reason: Messages.sessionEnded(mac: hostName, game: "Fake Game")), "trouble \(m.trouble)")
        XCTAssertEqual(m.screen, .playing)
        XCTAssertTrue(m.reconnecting, "the retry loop runs under the card")
        await m.reconnectNow()
        if case .ended = m.trouble {} else { XCTFail("Reconnect that misses lost the card: \(m.trouble)") }
    }

    /// "Apply and reconnect" during play to a Mac that is gone: the ended card at once.
    func testAFailedApplyAndReconnectDuringPlayEndsOnTheCard() async throws {
        let (m, p) = try await paired(retry: 30)
        try await play(m, p)
        await service.stop()
        await m.reconnectApplying()
        if case .ended = m.trouble {} else { XCTFail("no card after a failed apply: \(m.trouble)") }
        XCTAssertEqual(m.screen, .playing)
        XCTAssertTrue(m.reconnecting)
    }

    /// The ended card was up when the app went to the background: it is still up on return (the Mac still gone).
    func testGoingToTheBackgroundNeverLosesTheCard() async throws {
        let (m, p) = try await paired(retry: 30, silence: 1.5)
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let ended = await waitFor(6) { if case .ended = m.trouble { true } else { false } }
        XCTAssertTrue(ended)
        await service.stop()
        await m.background()
        if case .ended = m.trouble {} else { XCTFail("the background cleared the card: \(m.trouble)") }
        await m.foreground()
        if case .ended = m.trouble {} else { XCTFail("the card went on return: \(m.trouble)") }
    }

    /// A refusal on return (another device plays now): the ended card at once with the refusal's sentence, no retry loop.
    func testARefusalOnReturnDuringPlayEndsOnTheCardAtOnce() async throws {
        let (m2, _) = try await paired(name: "Device 2")
        await m2.leave()
        let (m1, p1) = try await paired(name: "Device 1")
        try await play(m1, p1)
        await m1.background()
        let paused = await pausedOnHost()
        XCTAssertTrue(paused)
        await m2.choose(found)
        let listed = await waitFor { m2.macState == .connected && m2.gameState?.run == .paused }
        XCTAssertTrue(listed, "m2 \(m2.macState) \(String(describing: m2.gameState))")
        await m2.resume()
        let plays = await waitFor { m2.screen == .playing }
        XCTAssertTrue(plays, "m2 screen \(m2.screen)")
        await m1.foreground()
        XCTAssertEqual(m1.trouble, .ended(reason: "Test Host is playing on Device 2."), "trouble \(m1.trouble)")
        XCTAssertEqual(m1.screen, .playing)
        XCTAssertFalse(m1.reconnecting, "a refusal is not retried")
    }

    func testReconnectOnTheEndedCardPicksThePlayUpAgain() async throws {
        let (m, p) = try await paired(retry: 30, silence: 1.5)
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let ended = await waitFor(6) { if case .ended = m.trouble { true } else { false } }
        XCTAssertTrue(ended, "trouble \(m.trouble)")
        let before = p.count
        await m.reconnectNow()
        XCTAssertEqual(m.trouble, .none)
        XCTAssertEqual(m.macState, .connected)
        let again = await waitFor(5) { m.screen == .playing && p.count >= before + 5 }
        XCTAssertTrue(again, "screen \(m.screen), pictures \(p.count - before): not playing again")
    }

    func testBackToGamesFromTheEndedCardIsALiveLibrary() async throws {
        let (m, p) = try await paired(retry: 30, silence: 1.5)
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let ended = await waitFor(6) { if case .ended = m.trouble { true } else { false } }
        XCTAssertTrue(ended)
        await m.leave()
        XCTAssertEqual(m.trouble, .none)
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.macState, .connected)
        XCTAssertNil(m.message)
    }

    /// The loop's give-up: the card goes and the library says the Mac is unreachable (a session that ends lands as C15 says).
    func testTheGiveUpUnderTheEndedCardLandsOnTheUnreachableLibrary() async throws {
        let (m, p) = try await paired(retry: 0.2, silence: 1.5, retryLimit: 1)
        try await play(m, p)
        await service.stop()
        let ended = await waitFor(6) { if case .ended = m.trouble { true } else { false } }
        XCTAssertTrue(ended, "trouble \(m.trouble)")
        let gone = await waitFor(6) { m.macState == .unreachable }
        XCTAssertTrue(gone, "state \(m.macState)")
        XCTAssertEqual(m.trouble, .none)
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(m.message, Messages.sentence(.stoppedAnswering, mac: hostName))
    }

    /// Each refusal is one sentence that says what to do; the busy one names the device the Host sent.
    func testRefusalsSayWhatToDo() async throws {
        let (m, _) = try await paired()
        m.goHome(.refused(.version(host: 3)), mac: "Den Mac")
        let version = try XCTUnwrap(m.message)
        XCTAssertTrue(version.contains("protocol 3"), version)
        XCTAssertTrue(version.contains("this app \(ProtocolVersion.network)"), version)
        XCTAssertTrue(version.hasSuffix("Update the older one."), version)
        m.goHome(.refused(.busy(device: "iPad mini 2")), mac: "Den Mac")
        XCTAssertEqual(m.message, "Den Mac is playing on iPad mini 2.")
        m.goHome(.refused(.unpaired), mac: "Den Mac")
        XCTAssertEqual(m.message, "Den Mac no longer knows this device. Pair again.")
    }

    private var pressA: InputState { InputState(seq: 0, player: 0, buttons: PadButtons.a.rawValue, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil) }

    /// The controller reports changes only: a button held through the whole stall, never touched, is held again on the
    /// Mac when the link is back.
    func testAButtonHeldThroughAStallIsHeldAgainAtRecovery() async throws {
        let (m, p) = try await paired(silence: 3)
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        let session = try XCTUnwrap(m.session)
        m.send(pressA)
        let held = await waitFor(1) { self.pads(game).last?.buttons == PadButtons.a.rawValue }
        XCTAssertTrue(held)
        await session.setIncomingDatagramFilter { _ in false }
        let stalled = await waitFor(2) { m.stalled }
        XCTAssertTrue(stalled)
        let neutral = await waitFor(1) { self.pads(game).last?.buttons == 0 }
        XCTAssertTrue(neutral)
        await session.setIncomingDatagramFilter(nil)  // nothing was sent to the model meanwhile
        let back = await waitFor(2) { self.pads(game).last?.buttons == PadButtons.a.rawValue }
        XCTAssertTrue(back, "the held button stayed neutral after the stall")
        XCTAssertFalse(m.stalled)
    }

    /// A control released during the stall is released at recovery (the newest real input is the neutral one).
    func testAControlReleasedDuringAStallStaysReleasedAtRecovery() async throws {
        let (m, p) = try await paired(silence: 3)
        try await play(m, p)
        let game = try XCTUnwrap(launcher.game)
        let session = try XCTUnwrap(m.session)
        m.send(pressA)
        let held = await waitFor(1) { self.pads(game).last?.buttons == PadButtons.a.rawValue }
        XCTAssertTrue(held)
        await session.setIncomingDatagramFilter { _ in false }
        let stalled = await waitFor(2) { m.stalled }
        XCTAssertTrue(stalled)
        m.send(ClientModel.neutral(0))  // released while the picture is frozen
        // The marker is taken once the neutral input has reached the game: datagrams sent before it may still be in flight.
        let neutral = await waitFor(1) { self.pads(game).last?.buttons == 0 }
        XCTAssertTrue(neutral)
        let marker = pads(game).count
        await session.setIncomingDatagramFilter(nil)
        let back = await waitFor(2) { !m.stalled }
        XCTAssertTrue(back)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(pads(game).dropFirst(marker).allSatisfy { $0.buttons == 0 }, "the released button was held again")
        XCTAssertEqual(pads(game).last?.buttons, 0)
    }

    /// A press during a stall, then the game is quit; a stall and recovery in the next game must not send that press.
    func testAPressDuringAStallIsNotCarriedIntoTheNextGame() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        let first = try XCTUnwrap(launcher.game)
        let id = try XCTUnwrap(m.link?.id)
        m.setStalled(true, link: id)
        m.send(pressA)
        await m.quitGame()
        let library = await waitFor(6) { m.screen == .library && m.games.first?.state == .idle }
        XCTAssertTrue(library, "screen \(m.screen)")
        m.setStalled(false, link: id)  // recovered while the gate is shut
        await m.launch(fakeEntry)
        let started = await waitFor { self.launcher.game !== first && self.launcher.game.map { !self.pads($0).isEmpty } == true && m.screen == .playing }
        XCTAssertTrue(started)
        let second = try XCTUnwrap(launcher.game)
        m.setStalled(true, link: id)
        m.setStalled(false, link: id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(pads(second).allSatisfy { $0.buttons == 0 }, "the old press reached the next game")
    }

    /// "Reconnecting..." stays until the first picture shown after recovery (a lone pong must not clear it over a
    /// frozen picture), or 1 s after the stall ended.
    func testTheOverlayStaysUntilAPictureIsShownOrASecondPasses() async throws {
        let (m, p) = try await paired(silence: 5)
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        XCTAssertFalse(m.showsReconnecting)
        await session.setIncomingDatagramFilter { _ in false }
        let stalled = await waitFor(2) { m.stalled }
        XCTAssertTrue(stalled)
        XCTAssertTrue(m.showsReconnecting)
        await session.setIncomingDatagramFilter(nil)
        let cleared = await waitFor(2) { !m.stalled }
        XCTAssertTrue(cleared)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(m.showsReconnecting, "cleared before any picture was shown")
        m.picturesShown(captureNs: 1, at: uptimeNs())
        XCTAssertFalse(m.showsReconnecting, "still shown after a picture")
        // The other way out: no picture reaches the display; 1 s after recovery it goes.
        await session.setIncomingDatagramFilter { _ in false }
        let again = await waitFor(2) { m.stalled }
        XCTAssertTrue(again)
        XCTAssertTrue(m.showsReconnecting)
        await session.setIncomingDatagramFilter(nil)
        let back = await waitFor(2) { !m.stalled }
        XCTAssertTrue(back)
        XCTAssertTrue(m.showsReconnecting)
        let timedOut = await waitFor(2) { !m.showsReconnecting }
        XCTAssertTrue(timedOut, "still shown 2 s after recovery")
    }

    /// Silence past the limit ends the session as before (`.silence`: the retry message), `stalled` goes with it.
    func testSilencePastTheLimitEndsTheStalledSession() async throws {
        let (m, p) = try await paired(retry: 30, silence: 3)
        try await play(m, p)
        let session = try XCTUnwrap(m.session)
        await session.setIncomingDatagramFilter { _ in false }
        let start = Date()
        let stalled = await waitFor(2) { m.stalled }
        XCTAssertTrue(stalled)
        let lost = await waitFor(4) { m.reconnecting }
        XCTAssertTrue(lost)
        XCTAssertTrue((2.5...3.8).contains(Date().timeIntervalSince(start)), "ended after \(Date().timeIntervalSince(start)) s of a 3 s limit")
        XCTAssertEqual(m.message, Messages.connectionLost)
        XCTAssertFalse(m.stalled)
    }

    func testTheModelsDefaultSilenceLimitIsTenSeconds() {
        let m = ClientModel(store: ClientStore(secrets: MemorySecrets()), browser: StubBrowser([]), deviceName: "D", kind: .tablet)
        XCTAssertEqual(m.silenceTimeout, 10)
    }

    func testLeaveDuringRefreshShowsNoMessage() async throws {
        let (m, _) = try await paired()
        let refreshing = Task { await m.refresh() }
        await Task.yield()  // the refresh is now waiting for its list reply
        await m.leave()
        await refreshing.value
        XCTAssertEqual(m.screen, .library)
        XCTAssertNil(m.message)
    }

    /// A tap while there is no link says so (`busyReconnecting`) and the loop goes on.
    func testCallOnDeadSessionSaysStillReconnecting() async throws {
        let (m, _) = try await paired(retry: 0.2, silence: 0.5)
        await service.stop()
        let lost = await waitFor(2) { m.reconnecting }
        XCTAssertTrue(lost)
        await m.launch(fakeEntry)
        XCTAssertEqual(m.message, Messages.busyReconnecting)
        XCTAssertTrue(m.reconnecting)
    }

    func testHeldButtonReleasedWhenGameEnds() async throws {
        let (m, p) = try await paired()
        try await play(m, p)
        let first = try XCTUnwrap(launcher.game)
        m.send(InputState(seq: 0, player: 0, buttons: PadButtons.a.rawValue, lx: 20_000, ly: 0, rx: 0, ry: 0, motion: nil))
        let held = await waitFor(1) { self.pads(first).contains { $0.buttons == PadButtons.a.rawValue && $0.lx == 20_000 } }
        XCTAssertTrue(held, "the held input did not reach the game")
        await m.quitGame()
        let library = await waitFor(6) { m.screen == .library && m.games.first?.state == .idle }
        XCTAssertTrue(library, "screen \(m.screen)")
        await m.launch(fakeEntry)
        let started = await waitFor { self.launcher.game !== first && self.launcher.game.map { !self.pads($0).isEmpty } == true }
        XCTAssertTrue(started, "the second game got no pad")
        let second = try XCTUnwrap(launcher.game)
        let pad = try XCTUnwrap(pads(second).first)
        XCTAssertEqual(pad.buttons, 0, "a button held in the last game is still held")
        XCTAssertEqual([pad.lx, pad.ly, pad.rx, pad.ry], [0, 0, 0, 0], "a stick held in the last game is still held")
    }

    func testResetStoreRecovers() async throws {
        let secrets = MemorySecrets()
        try secrets.write("identity", Data([1, 2, 3]))
        try secrets.write("hosts", Data("not json".utf8))
        let (m, _) = model(secrets)
        await m.choose(found)
        XCTAssertTrue(m.storeFailed)
        XCTAssertEqual(m.message, Messages.storeFailed)
        await m.resetStore()
        XCTAssertFalse(m.storeFailed)
        XCTAssertNil(m.message)
        await m.choose(found)
        XCTAssertEqual(m.screen, .pairing(found))
        XCTAssertFalse(m.storeFailed)
    }

    func testDiscoveryBlockedIsShown() async throws {
        let browser = StubBrowser([found])
        let (m, _) = model(browser: browser)
        XCTAssertNil(m.discoveryMessage)
        browser.fail.yield(true)
        let blocked = await waitFor(1) { m.discoveryMessage == Messages.discoveryBlocked }
        XCTAssertTrue(blocked, "discoveryMessage \(m.discoveryMessage ?? "-")")
        browser.fail.yield(false)
        let cleared = await waitFor(1) { m.discoveryMessage == nil }
        XCTAssertTrue(cleared)
    }

    /// Minor 5: back in the foreground, discovery restarts while it is blocked or the Macs list shows.
    func testForegroundRestartsDiscoveryWhenBlocked() async throws {
        let browser = StubBrowser([found])
        let (m, _) = try await paired(browser: browser)
        await m.foreground()
        XCTAssertEqual(browser.restarts.value, 0, "restarted while discovery works and the library shows")
        browser.fail.yield(true)
        let blocked = await waitFor(1) { m.discoveryMessage != nil }
        XCTAssertTrue(blocked)
        await m.foreground()
        XCTAssertEqual(browser.restarts.value, 1, "not restarted while blocked")
        browser.fail.yield(false)
        let cleared = await waitFor(1) { m.discoveryMessage == nil }
        XCTAssertTrue(cleared)
        await m.disconnect()
        await m.foreground()
        XCTAssertEqual(browser.restarts.value, 2, "not restarted on the Macs screen")
    }

    /// Minor 9: the Host's answer did not verify (it did not know the code) -> its own message, not "did not answer".
    func testHostProofInvalidHasItsOwnMessage() {
        XCTAssertEqual(ClientModel.describe(PairingError.hostProofInvalid), Messages.codeDidNotMatch)
        XCTAssertEqual(Messages.codeDidNotMatch, "The code did not match. Start pairing on the Mac again.")
        XCTAssertEqual(ClientModel.describe(ClientError.timeout), Messages.unreachable)
    }

    func testConcurrentPairUsesCodeOnce() async throws {
        let secrets = MemorySecrets()
        let (m, _) = model(secrets)
        await m.choose(found)
        let code = try await service.beginPairing()
        let a = Task { await m.pair(code: code) }
        let b = Task { await m.pair(code: code) }
        await Task.yield()  // both calls have run up to their first wait
        XCTAssertTrue(m.busy, "busy not set while pairing")
        await a.value
        await b.value
        let library = await waitFor { m.screen == .library }
        XCTAssertTrue(library, "screen \(m.screen), message \(m.message ?? "-")")
        XCTAssertNil(m.message)
        XCTAssertFalse(m.busy)
        XCTAssertEqual(try ClientStore(secrets: secrets).hosts().map(\.name), [hostName])
    }

    // MARK: client follow-ups -> .claude/client.md § model, § discovery

    private func restartService(launcher newLauncher: FakeLauncher? = nil, name: String? = nil) async throws {
        await service.stop()
        if let newLauncher { launcher = newLauncher }
        service = try makeService(port: newLauncher == nil ? port : 0, name: name)
        port = try await service.start()
    }

    func testRenamedMacIsRecognisedByItsID() async throws {
        let secrets = MemorySecrets()
        let (first, _) = try await paired(secrets)
        await first.disconnect()
        try await restartService(name: hostName + " (2)")
        let renamed = FoundHost(name: hostName + " (2)", endpoint: found.endpoint, id: service.discoveryID)
        let (m, _) = model(secrets)
        await m.choose(renamed)
        let library = await waitFor { m.screen == .library }
        XCTAssertTrue(library, "screen \(m.screen), message \(m.message ?? "-")")
        XCTAssertEqual(try ClientStore(secrets: secrets).hosts().map(\.name), [hostName + " (2)"])
        XCTAssertEqual(m.hostName, hostName + " (2)")
    }

    func testSameNameOtherKeyAsksToPair() async throws {
        let secrets = MemorySecrets()
        let (first, _) = try await paired(secrets)
        await first.disconnect()
        let other = FoundHost(name: hostName, endpoint: found.endpoint, id: "0123456789abcdef")
        let (m, _) = model(secrets)
        await m.choose(other)
        XCTAssertEqual(m.screen, .pairing(other))
    }

    func testHostNameWhileConnected() async throws {
        let (m, _) = try await paired()
        XCTAssertEqual(m.hostName, hostName)
        await m.leave()
        XCTAssertEqual(m.hostName, hostName, "the library keeps the Mac's name while it is not connected")
    }

    /// The Mac's `preparing` reaches the model with the preparing time, and ends with the first picture.
    func testThePreparingStateReachesTheModel() async throws {
        try await restartService(launcher: FakeLauncher(stall: 1.5))
        let (m, _) = try await paired()
        XCTAssertNil(m.preparing)
        await m.launch(fakeEntry)
        let progress = await waitFor { (m.preparing?.total ?? 0) > 0 }
        XCTAssertTrue(progress, "no progress: \(String(describing: m.gameState))")
        XCTAssertNotNil(m.preparingSince)
        let since = m.preparingSince
        XCTAssertEqual(m.preparing(for: fakeEntry.titleID)?.phase, 1)
        XCTAssertNil(m.preparing(for: "OTHER"))
        let done = await waitFor(5) { m.preparing == nil && m.gameState?.run == .running }
        XCTAssertTrue(done, "still preparing: \(String(describing: m.preparing))")
        XCTAssertNil(m.preparingSince)
        XCTAssertNotNil(since)
    }

    func testRemovedOnTheMacAsksToPairAgain() async throws {
        let secrets = MemorySecrets()
        let (m, _) = try await paired(secrets, retry: 0.2)
        let id = try ClientStore(secrets: secrets).identity().publicKey
        try await service.removeDevice(id)
        let again = await waitFor(5) { if case .pairing = m.screen { true } else { false } }
        XCTAssertTrue(again, "screen \(m.screen), message \(m.message ?? "-")")
        XCTAssertEqual(m.message, Messages.refusal(.unpaired, mac: hostName))
        XCTAssertEqual(try ClientStore(secrets: secrets).hosts(), [], "the Mac stayed stored")
    }

    func testLaunchWhileOtherGamePausedShowsReason() async throws {
        let (m1, p1) = try await paired(name: "Device 1")
        try await play(m1, p1)
        await m1.leave()
        let paused = await pausedOnHost()
        XCTAssertTrue(paused)
        let (m2, _) = try await paired(name: "Device 2")
        await m2.launch(fakeEntry)
        let said = await waitFor { m2.message == "Fake Game is running." }
        XCTAssertTrue(said, "message \(m2.message ?? "-"), screen \(m2.screen)")
        XCTAssertEqual(m2.screen, .library)
    }

    func testTapWhileReconnectingSaysSo() async throws {
        let (m, p) = try await paired(retry: 0.2, silence: 0.5)
        try await play(m, p)
        await service.stop()
        let lost = await waitFor(3) { m.reconnecting && m.message == Messages.connectionLost }
        XCTAssertTrue(lost)
        await m.launch(fakeEntry)
        XCTAssertEqual(m.message, Messages.busyReconnecting)
        XCTAssertEqual(Messages.busyReconnecting, "Still reconnecting to the Mac.")
    }

    func testRetryGivesUp() async throws {
        let (m, p) = try await paired(retry: 0.2, silence: 0.5, retryLimit: 1)
        try await play(m, p)
        await service.stop()
        var seen: [ClientModel.Screen] = []
        let gone = await waitFor(6) {
            if seen.last != m.screen { seen.append(m.screen) }
            return m.macState == .unreachable
        }
        XCTAssertTrue(gone, "screen \(m.screen), reconnecting \(m.reconnecting)")
        XCTAssertEqual(m.screen, .library, "a session that ends stays on the library: \(seen)")
        XCTAssertFalse(seen.contains(.hosts), "\(seen)")
        XCTAssertEqual(m.message, Messages.sentence(.stoppedAnswering, mac: hostName))
        XCTAssertFalse(m.reconnecting)
        XCTAssertEqual(m.hostName, hostName)
    }

    /// An attempt that itself takes 5 s (a Mac that accepts and never answers) must not push the give-up past its limit
    /// by another interval.
    func testRetryLimitHoldsAfterASlowAttempt() async throws {
        let (m, p) = try await paired(retry: 1.5, silence: 0.5, retryLimit: 3)
        try await play(m, p)
        await service.stop()
        // The stopped Host's port may take a moment to come free: bind again until it does.
        let held = HeldConnections()
        var bound: NWListener?
        for _ in 0..<20 where bound == nil {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let candidate = try? NWListener(using: params, on: try XCTUnwrap(NWEndpoint.Port(rawValue: port))) else {
                await sleep(0.25); continue
            }
            let ready = Counter(), failed = Counter()
            candidate.newConnectionHandler = { c in held.add(c); c.start(queue: .global()) }
            candidate.stateUpdateHandler = { switch $0 { case .ready: ready.bump(); case .failed, .cancelled: failed.bump(); default: break } }
            candidate.start(queue: .global())
            let up = await waitFor(1) { ready.value > 0 || failed.value > 0 }
            if up, ready.value > 0 { bound = candidate } else { candidate.cancel(); await sleep(0.25) }
        }
        let listener = try XCTUnwrap(bound, "could not take the stopped Host's port")
        defer { listener.cancel(); held.cancelAll() }
        let lost = await waitFor(3) { m.reconnecting }
        XCTAssertTrue(lost, "not reconnecting: screen \(m.screen) message \(m.message ?? "-")")
        let start = Date()
        let gone = await waitFor(12) { m.macState == .unreachable }
        XCTAssertTrue(gone, "screen \(m.screen)")
        XCTAssertGreaterThan(held.count, 0, "no attempt reached the slow listener: the rule was not exercised")
        // First attempt at 1.5 s, answered (timeout) at about 6.5 s; one more interval would make it 8 s.
        XCTAssertLessThan(Date().timeIntervalSince(start), 7.2, "the limit was only checked after another sleep")
        XCTAssertEqual(m.message, Messages.sentence(.stoppedAnswering, mac: hostName))
    }

    /// A Mac that accepts and never answers holds a pairing exchange open.
    func testPairAfterCancelIsAccepted() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = HeldConnections()
        listener.newConnectionHandler = { c in held.add(c); c.start(queue: .global()) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        defer { listener.cancel(); held.cancelAll() }
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success)
        let silent = FoundHost(name: "Silent Mac", endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)))
        let (m, _) = model()
        await m.choose(silent)
        XCTAssertEqual(m.screen, .pairing(silent))
        let stuck = Task { await m.pair(code: "000000") }
        let began = await waitFor { m.busy }
        XCTAssertTrue(began)
        m.cancelPairing()
        await m.choose(found)
        XCTAssertEqual(m.screen, .pairing(found))
        let code = try await service.beginPairing()
        let start = Date()
        await m.pair(code: code)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "waited for the superseded exchange")
        let library = await waitFor { m.screen == .library }
        XCTAssertTrue(library, "screen \(m.screen), message \(m.message ?? "-")")
        stuck.cancel()
    }

    func testInputWantedWhenPlayBegins() async throws {
        let (m, p) = try await paired()
        let asked = Counter()
        m.onInputWanted = { asked.bump() }
        try await play(m, p)
        XCTAssertGreaterThanOrEqual(asked.value, 1, "the view was not asked for the present input")
    }

    // MARK: artwork, Continue, last tile -> .claude/client.md § model

    private let artID = "FAKE0000000000A1"

    /// The Host again on the same port, with one more game whose icon `FakeArt` draws in the test's folder.
    private func serveArtGame(_ paint: FakeArt.Paint = .gradient(0x3366FF, 0xFF3300)) async throws -> URL {
        let app = try FakeArt.makeApp(in: dir.appendingPathComponent("lib"), titleID: artID, name: "Art Game", paint: paint)
        await service.stop()
        service = try makeService(port: port, extraGames: [GameApp(titleID: artID, name: "Art Game", url: app, streamable: true)])
        port = try await service.start()
        return app
    }

    private func artFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    }

    func testAListedIconIsAskedOnceKeptAndAskedAgainOnlyForANewHash() async throws {
        let app = try await serveArtGame()
        let artDir = dir.appendingPathComponent("art")
        let (m, _) = try await paired(artCache: ArtCache(directory: artDir))
        let game = try XCTUnwrap(m.games.first { $0.titleID == artID })
        let first = try XCTUnwrap(game.art)
        let arrived = await waitFor { m.art(for: game) != nil }
        XCTAssertTrue(arrived, "the icon never arrived")
        XCTAssertEqual(m.art(for: game).map(ArtCache.hash), first.hash)
        XCTAssertEqual(m.artRequestsSent, 1)
        XCTAssertNil(m.art(for: try XCTUnwrap(m.games.first { $0.titleID == fakeID })), "a game without an icon")
        let lit = await waitFor { m.palette(for: game).hasGlow }
        XCTAssertTrue(lit, "the palette of a coloured icon")
        XCTAssertFalse(m.palette(for: try XCTUnwrap(m.games.first { $0.titleID == fakeID })).hasGlow, "no icon: slate")

        await m.refresh()
        await sleep(0.3)
        XCTAssertEqual(m.artRequestsSent, 1, "the same hash is not asked again")

        let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        try FakeArt.write(FakeArt.image(.flat(0x33CC66), side: 1024), to: icon)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: icon.path)
        await m.refresh()
        let second = try XCTUnwrap(m.games.first { $0.titleID == artID }?.art)
        XCTAssertNotEqual(second.hash, first.hash)
        let again = await waitFor { m.games.first { $0.titleID == self.artID }.flatMap { m.art(for: $0) }.map(ArtCache.hash) == second.hash }
        XCTAssertTrue(again, "the new icon never arrived")
        XCTAssertEqual(m.artRequestsSent, 2)
        XCTAssertEqual(artFiles(artDir), ["\(artID)-\(second.hash).png"], "the old file is removed")
    }

    /// An older ask's 15 s timer must not cut short a later transfer of the same icon.
    func testAnOlderGiveUpTimerDoesNotCutShortALaterTransferOfTheSameIcon() async throws {
        _ = try await serveArtGame()
        let (m, _) = try await paired(artCache: ArtCache(directory: dir.appendingPathComponent("art")))
        let game = try XCTUnwrap(m.games.first { $0.titleID == artID })
        let ref = try XCTUnwrap(game.art)
        let arrived = await waitFor { m.art(for: game) != nil }
        XCTAssertTrue(arrived)
        let linkID = try XCTUnwrap(m.link?.id)
        let firstGeneration = try XCTUnwrap(m.artGenerations[artID])
        // The same icon is asked again (it was let go and listed again) and is on its way.
        m.artData[ClientModel.artKey(artID, ref.hash)] = nil
        m.artInFlight[artID] = nil
        m.artQueue = [(artID, ref)]
        m.pumpArt()
        let secondGeneration = try XCTUnwrap(m.artGenerations[artID])
        XCTAssertNotEqual(secondGeneration, firstGeneration)
        m.artInFlight[artID] = try XCTUnwrap(ArtTransfer(titleID: artID, ref: ref))  // still waiting for its chunks
        m.artGaveUp(artID, generation: firstGeneration, link: linkID)
        XCTAssertNotNil(m.artInFlight[artID], "the first ask's timer ended the second transfer")
        m.artGaveUp(artID, generation: secondGeneration, link: linkID)
        XCTAssertNil(m.artInFlight[artID], "its own timer still gives it up")
    }

    func testAChunkForATitleNotAskedIsDroppedAndNothingIsWritten() async throws {
        let artDir = dir.appendingPathComponent("art")
        let (m, _) = try await paired(artCache: ArtCache(directory: artDir))
        let id = try XCTUnwrap(m.link?.id)
        let png = Data(repeating: 7, count: 100)
        m.artChunk(ArtChunk(titleID: fakeID, hash: ArtCache.hash(png), index: 0, count: 1, bytes: png), link: id)
        await sleep(0.2)
        XCTAssertEqual(artFiles(artDir), [])
        XCTAssertNil(m.art(for: GameEntry(titleID: fakeID, name: "Fake Game", streamable: true, state: .idle,
                                          art: ArtRef(hash: ArtCache.hash(png), bytes: 100))))
    }

    func testRefreshAsksTheHostForTheListAgain() async throws {
        let (m, _) = try await paired()
        let before = m.listAsked
        await m.refresh()
        XCTAssertEqual(m.listAsked, before + 1)
    }

    func testContinueIsThePausedGameThenTheLastPlayed() async throws {
        let (m1, p1) = try await paired(name: "Device 1")
        try await play(m1, p1)
        await m1.leave()
        _ = await pausedOnHost()
        let cache = LibraryCache(directory: dir.appendingPathComponent("libraries"))
        let (m, _) = try await paired(name: "Device 2", cache: cache)
        XCTAssertEqual(m.continueGame?.titleID, fakeID, "the game another device paused")
        XCTAssertEqual(m.continueGame?.state, .paused)
        await m.resume()
        _ = await waitFor { m.screen == .playing }
        await m.quitGame()
        let idle = await waitFor(6) { m.screen == .library && m.games.first { $0.titleID == self.fakeID }?.state == .idle }
        XCTAssertTrue(idle, "screen \(m.screen)")
        XCTAssertEqual(m.continueGame?.titleID, fakeID, "after a quit: the last played")
        XCTAssertEqual(m.continueGame?.state, .idle)
        let key = try XCTUnwrap(m.current?.key)
        XCTAssertEqual(cache.lastPlayed(for: key), fakeID, "kept for the next start")
    }

    func testNothingPlayedHereIsNoContinue() async throws {
        let (m, _) = try await paired()
        XCTAssertNil(m.continueGame)
    }

    func testLaunchingFromATileSetsTheLastTileLeaveKeepsItANewLaunchReplacesIt() async throws {
        _ = try await serveArtGame()
        let (m, p) = try await paired()
        XCTAssertNil(m.lastPlayedTile)
        try await play(m, p)
        XCTAssertEqual(m.lastPlayedTile, fakeID)
        await m.leave()
        XCTAssertEqual(m.lastPlayedTile, fakeID)
        await m.choose(found)
        _ = await waitFor { m.screen == .playing || m.screen == .library }
        let other = try XCTUnwrap(m.games.first { $0.titleID == artID })
        await m.launch(other)
        XCTAssertEqual(m.lastPlayedTile, artID)
    }

    func testQuitUnconfirmed() async throws {
        try await restartService(launcher: FakeLauncher(ignoresQuit: true))
        let (m, p) = try await paired(quitWait: 0.5)
        try await play(m, p)
        await m.quitGame()
        let unconfirmed = await waitFor(2) { m.message == Messages.quitUnconfirmed }
        XCTAssertTrue(unconfirmed, "message \(m.message ?? "-")")
        // The Host ends a game that outlives its quit grace; its idle state returns the model to the library.
        let library = await waitFor(10) { m.screen == .library && m.games.first?.state == .idle }
        XCTAssertTrue(library, "screen \(m.screen), games \(m.games)")
    }

    // MARK: per-game options -> .claude/client.md § model

    private let optID = "FAKE0000000000B1"

    /// The Host again on the same port, with one more game whose own `launcher.json` is generated here: made-up variables and
    /// labels. Returns the game's entry.
    private func serveOptionsGame() async throws {
        let app = dir.appendingPathComponent("lib/Options.app")
        let resources = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let rows: [[String: Any]] = [
            ["env": "DM_LANG", "kind": "choice", "section": "Game", "label": "Voice language", "note": "", "default": "a",
             "options": [["a", "Alpha"], ["b", "Beta"]], "level": "basic"],
            ["env": "DM_SCALE", "kind": "range", "section": "Game", "label": "Picture scale", "note": "", "default": "1.0",
             "min": 0.5, "max": 1.0, "step": 0.05, "level": "basic",
             "base": ["docked": [1600, 900], "handheld": [1280, 720]]],
            ["env": "DM_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold frames", "note": "", "default": "off",
             "on": "on", "off": "off"],
            ["env": "DM_DIAL", "kind": "dial", "section": "Performance", "label": "A dial", "note": "", "default": "x"],
        ]
        let json = try JSONSerialization.data(withJSONObject: ["schema": 1, "settings": rows])
        try json.write(to: resources.appendingPathComponent("launcher.json"))
        try await restartService(with: GameApp(titleID: optID, name: "Options Game", url: app, streamable: true))
    }

    /// The Host again on the same port with `game` added (a stop returns when the port is free).
    private func restartService(with game: GameApp) async throws {
        await service.stop()
        service = try makeService(port: port, extraGames: [game])
        port = try await service.start()
    }

    private func setting(_ m: ClientModel, _ env: String) -> OptionSetting? { m.options(for: optID)?.settings.first { $0.env == env } }

    func testLoadingFillsTheListInTheGamesOrderAndAGameWithoutOneGetsAnEmptyList() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        XCTAssertNil(m.options(for: optID), "nothing is known before the page asks")
        await m.loadOptions(titleID: optID)
        let o = try XCTUnwrap(m.options(for: optID))
        XCTAssertEqual(o.settings.map(\.env), ["DM_LANG", "DM_SCALE", "DM_HOLD", "DM_DIAL"])
        XCTAssertEqual(o.settings.map(\.label), ["Voice language", "Picture scale", "Hold frames", "A dial"])
        XCTAssertTrue(o.settings.allSatisfy { !$0.chosen && $0.current == $0.defaultValue })
        XCTAssertNil(m.options(for: fakeID))
        await m.loadOptions(titleID: fakeID)
        XCTAssertEqual(m.options(for: fakeID)?.settings.count, 0, "a game with no list: an empty list, not 'not loaded'")
    }

    func testASetShowsAtOnceAndThenTheHostHasIt() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        let t = Task { await m.setOption(titleID: optID, env: "DM_SCALE", value: "0.75") }
        await Task.yield()
        XCTAssertEqual(setting(m, "DM_SCALE")?.current, "0.75", "shown before the Host has answered")
        XCTAssertEqual(setting(m, "DM_SCALE")?.chosen, true)
        await t.value
        XCTAssertEqual(setting(m, "DM_SCALE")?.current, "0.75")
        XCTAssertNil(m.message)
        await m.loadOptions(titleID: optID)  // from the Host again
        XCTAssertEqual(setting(m, "DM_SCALE")?.current, "0.75")
        XCTAssertEqual(setting(m, "DM_SCALE")?.chosen, true)
    }

    func testTwoQuickChangesToOneRowEndAtTheLastOne() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        let a = Task { await m.setOption(titleID: optID, env: "DM_SCALE", value: "0.6") }
        let b = Task { await m.setOption(titleID: optID, env: "DM_SCALE", value: "0.9") }
        var seen: [String] = []
        let end = Date().addingTimeInterval(5)
        while Date() < end, m.optionsPending(titleID: optID) {
            if let c = setting(m, "DM_SCALE")?.current, seen.last != c { seen.append(c) }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await a.value; await b.value
        XCTAssertFalse(seen.contains("0.6"), "the row never went back to the first change: \(seen)")
        XCTAssertEqual(setting(m, "DM_SCALE")?.current, "0.9")
        await m.loadOptions(titleID: optID)
        XCTAssertEqual(setting(m, "DM_SCALE")?.current, "0.9", "the Host kept the last one")
    }

    func testARejectedValueRestoresTheOldOneAndTheMessageNamesTheLabel() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        await m.setOption(titleID: optID, env: "DM_LANG", value: "b")
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "b")
        await m.setOption(titleID: optID, env: "DM_LANG", value: "zz")  // not offered by the list: the Host refuses
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "b", "back to what it was")
        XCTAssertEqual(setting(m, "DM_LANG")?.chosen, true)
        XCTAssertEqual(m.message, OptionText.rejected(label: "Voice language"))
    }

    func testResetReturnsEveryRowToItsDefault() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        await m.setOption(titleID: optID, env: "DM_LANG", value: "b")
        await m.setOption(titleID: optID, env: "DM_HOLD", value: "on")
        XCTAssertEqual(m.options(for: optID)?.settings.filter(\.chosen).count, 2)
        await m.resetOptions(titleID: optID)
        let o = try XCTUnwrap(m.options(for: optID))
        XCTAssertTrue(o.settings.allSatisfy { !$0.chosen && $0.current == $0.defaultValue })
        await m.loadOptions(titleID: optID)
        XCTAssertTrue(m.options(for: optID)?.settings.allSatisfy { !$0.chosen } ?? false, "the Host has none either")
    }

    func testOptionsWorkInAPlayingSessionToo() async throws {
        try await serveOptionsGame()
        let (m, p) = try await paired()
        try await play(m, p)
        await m.loadOptions(titleID: optID)
        await m.setOption(titleID: optID, env: "DM_HOLD", value: "on")
        XCTAssertEqual(setting(m, "DM_HOLD")?.current, "on")
        XCTAssertEqual(m.screen, .playing, "the game keeps going")
    }

    /// The made-up list `portal-hostd --fake-options` serves (the screenshots' fixture) reads through the Host and draws.
    func testTheTestToolsSampleListReachesTheAppAndDraws() async throws {
        strictOptions = true  // the tool's own list passes the real gate: nothing is widened for it
        let app = try FakeArt.makeApp(in: dir.appendingPathComponent("lib"), titleID: optID, name: "Sample", paint: nil,
                                      options: FakeArt.sampleOptions)
        try await restartService(with: GameApp(titleID: optID, name: "Sample", url: app, streamable: true))
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        let o = try XCTUnwrap(m.options(for: optID))
        XCTAssertEqual(o.settings.count, FakeArt.sampleOptions.count)
        let rows = OptionRows(o)
        XCTAssertEqual(rows.sections.map(\.title), ["Game", "Performance"])
        XCTAssertEqual(rows.renderScale?.label, "Render scale")
        XCTAssertEqual(rows.all.first { $0.id == "DM_RUMBLE_GAIN" }?.editor, .readOnly)
        XCTAssertEqual(rows.menuRows(values: OptionRows.values(o)).first?.label, "Render scale")
    }

    func testAnotherMacsOptionsNeverShowAfterASwitch() async throws {
        let secrets = MemorySecrets()
        let (svcA, portA) = try await secondHost(name: "Host A")
        defer { Task { await svcA.stop() } }
        try await serveOptionsGame()
        let a = try await pairWith(svcA, port: portA, secrets: secrets, as: "Mac A")
        let b = try await pairWith(service, port: port, secrets: secrets, as: "Mac B")
        try ClientStore(secrets: secrets).setLast(hostKey: b.key)
        let browser = StubBrowser([foundHost("Mac A", port: portA, id: Identity.discoveryID(publicKey: a.key)),
                                   foundHost("Mac B", port: port, id: Identity.discoveryID(publicKey: b.key))])
        let (m, _) = model(secrets, browser: browser)
        let up = await waitFor { m.macState == .connected && m.hostName == "Mac B" }
        XCTAssertTrue(up, "state \(m.macState)")
        await m.loadOptions(titleID: optID)
        XCTAssertEqual(m.options(for: optID)?.settings.count, 4)
        await m.switchMac(try XCTUnwrap(m.macRows.first { $0.name == "Mac A" }))
        XCTAssertEqual(m.hostName, "Mac A")
        XCTAssertNil(m.options(for: optID), "Mac B's list is gone with its session")
        await m.loadOptions(titleID: optID)
        XCTAssertEqual(m.options(for: optID)?.settings.count, 0, "Mac A has no such game: its own answer")
    }

    /// A reply over the limits is ignored by the session (it goes on), the call returns, the wish goes back, and the next
    /// valid reply is shown.
    func testARefusedOptionsReplyNeverLeavesACallWaiting() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "a")
        let link = m.link?.id
        m.optionReplyTimeout = 30  // only the refusal itself may end the wait here
        answerHook.once { o in var o = o; o.settings[0].label = String(repeating: "x", count: 900_000); return o }
        let started = Date()
        await m.setOption(titleID: optID, env: "DM_LANG", value: "b")  // returns: it does not wait for a reply that never comes
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(m.link?.id, link, "the session goes on")
        XCTAssertEqual(m.screen, .library)
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "a", "the wish went back")
        XCTAssertEqual(m.message, OptionText.rejected(label: "Voice language"))
        XCTAssertFalse(m.optionsPending(titleID: optID))
        await m.setOption(titleID: optID, env: "DM_LANG", value: "b")  // the next valid reply is shown
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "b")
        XCTAssertEqual(setting(m, "DM_LANG")?.chosen, true)
    }

    func testAFullMacIsSaidInItsOwnSentence() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        answerHook.once { o in var o = o; o.rejected = "DM_LANG"; o.full = true; return o }
        await m.setOption(titleID: optID, env: "DM_LANG", value: "b")
        XCTAssertEqual(m.message, OptionText.macFull)
        XCTAssertEqual(OptionText.macFull, "This change was not kept: the Mac already keeps choices for as many games as it can.")
        XCTAssertEqual(OptionText.didNotAnswer(label: "Frame rate"), "Frame rate may not have changed. The Mac did not answer.")
    }

    func testARefusedListReplyIsSaidNotShownAsLoadingForEver() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        m.optionReplyTimeout = 30
        answerHook.once { o in var o = o; o.settings[0].label = String(repeating: "x", count: 900_000); return o }
        let started = Date()
        await m.loadOptions(titleID: optID)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNil(m.options(for: optID))
        XCTAssertEqual(m.optionsState(for: optID), .unavailable)
        XCTAssertEqual(m.message, OptionText.couldNotLoad)
        await m.loadOptions(titleID: optID)
        XCTAssertEqual(m.optionsState(for: optID), .loaded)
    }

    /// Second line of defence: a Mac that never answers does not hold the call for ever.
    func testACallStopsWaitingWhenTheMacNeverAnswers() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        m.optionReplyTimeout = 0.3
        answerHook.once { _ in nil }  // the Mac sends nothing
        let started = Date()
        await m.setOption(titleID: optID, env: "DM_LANG", value: "b")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "the bound, not the session's end")
        XCTAssertFalse(m.optionsPending(titleID: optID))
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "a", "the wish went back")
        XCTAssertEqual(m.message, OptionText.didNotAnswer(label: "Voice language"))
    }

    func testAReplyForAGameNobodyAskedAboutIsDroppedAndOneForAnotherSessionToo() async throws {
        let (m, _) = try await paired()
        let id = try XCTUnwrap(m.link?.id)
        let stray = GameOptions(titleID: "STRAY0001", settings: [])
        m.optionsReply(stray, link: id)
        XCTAssertNil(m.options(for: "STRAY0001"))
        await m.loadOptions(titleID: fakeID)
        m.optionsReply(GameOptions(titleID: fakeID, settings: [OptionRowsTests.choice("DM_LATE", "Late")]), link: id + 1)
        XCTAssertEqual(m.options(for: fakeID)?.settings.count, 0, "a reply of another session changes nothing")
    }

    func testWhatTheHostSendsIsCleanedBeforeItIsKept() async throws {
        let (m, _) = try await paired()
        let id = try XCTUnwrap(m.link?.id)
        await m.loadOptions(titleID: fakeID)
        var dirty = OptionRowsTests.choice("DM_OK", "  Cl\u{0000}ean\n")
        dirty.note = String(repeating: "n", count: 5000)
        m.optionsReply(GameOptions(titleID: fakeID, settings: [dirty, OptionRowsTests.choice("bad name", "x")]), link: id)
        let o = try XCTUnwrap(m.options(for: fakeID))
        XCTAssertEqual(o.settings.map(\.label), ["Clean"])
        XCTAssertEqual(o.settings.first?.note.count, OptionClean.maxNote)
    }

    private struct CouldNotSend: Error {}

    func testAMessageThatCannotGoPutsTheOldValueBackAndSaysSo() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        await m.setOption(titleID: optID, env: "DM_LANG", value: "b")
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "b")
        m.optionSendHook = { throw CouldNotSend() }
        await m.setOption(titleID: optID, env: "DM_LANG", value: "a")
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "b", "the old value is back")
        XCTAssertEqual(setting(m, "DM_LANG")?.chosen, true)
        XCTAssertEqual(m.message, OptionText.notSent(label: "Voice language"))
        XCTAssertFalse(m.optionsPending(titleID: optID), "nothing is waited for that never went")
        m.message = nil
        await m.resetOptions(titleID: optID)
        XCTAssertEqual(setting(m, "DM_LANG")?.chosen, true, "a reset that did not go leaves the choices showing")
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "b")
        XCTAssertEqual(m.message, OptionText.resetNotSent)
        m.optionSendHook = nil
        await m.setOption(titleID: optID, env: "DM_LANG", value: "a")
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "a", "and it works again once messages go")
    }

    func testAMalformedTitleIsUnavailableNeverLoadingForEver() async throws {
        let (m, _) = try await paired()
        for bad in ["", "not a title", String(repeating: "A", count: 400)] {
            XCTAssertEqual(m.optionsState(for: bad), .unavailable, bad)
        }
    }

    func testAResetThatCannotGoKeepsTheChangesStillWaitingForTheirAnswer() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        m.optionWishes[optID] = ["DM_LANG": OptionWish(value: "b", seq: 1)]  // a change sent and not yet answered
        m.optionInFlight[optID] = 1
        m.optionSendHook = { throw CouldNotSend() }
        await m.resetOptions(titleID: optID)
        XCTAssertEqual(m.message, OptionText.resetNotSent)
        XCTAssertEqual(setting(m, "DM_LANG")?.current, "b", "the change is still shown")
        XCTAssertEqual(m.optionWishes[optID]?["DM_LANG"]?.value, "b")
    }

    func testAPageOfATitleBeyondTheSessionsLimitIsUnavailableNotLoadingForever() async throws {
        let (m, _) = try await paired()
        XCTAssertEqual(m.optionsState(for: "TT0000"), .loading, "not asked yet, room left: loading")
        for i in 0..<ClientModel.maxOptionTitles { await m.loadOptions(titleID: "TT\(String(format: "%04d", i))") }
        XCTAssertEqual(m.optionsState(for: "TT0000"), .loaded)
        XCTAssertEqual(m.optionsState(for: "TT9999"), .unavailable)
        await m.loadOptions(titleID: "TT9999")
        XCTAssertNil(m.options(for: "TT9999"))
        XCTAssertEqual(m.optionsState(for: "TT9999"), .unavailable)
        await m.disconnect()
        XCTAssertEqual(m.optionsState(for: "TT0000"), .unavailable, "no session: not loading either")
    }

    func testTheEndOfTheSessionDropsEveryListAndEveryPendingChange() async throws {
        try await serveOptionsGame()
        let (m, _) = try await paired()
        await m.loadOptions(titleID: optID)
        _ = Task { await m.setOption(titleID: optID, env: "DM_LANG", value: "b") }
        await Task.yield()
        XCTAssertTrue(m.optionsPending(titleID: optID))
        await m.disconnect()
        XCTAssertNil(m.options(for: optID))
        XCTAssertFalse(m.optionsPending(titleID: optID))
        await m.setOption(titleID: optID, env: "DM_LANG", value: "a")  // no session: nothing shown, nothing thrown
        XCTAssertNil(m.options(for: optID))
    }
}
#endif

#if os(macOS)
/// Connections a test listener accepted and keeps open without answering.
final class HeldConnections: @unchecked Sendable {
    private let lock = NSLock()  // guards list
    private var list: [NWConnection] = []
    func add(_ c: NWConnection) { lock.withLock { list.append(c) } }
    func cancelAll() { lock.withLock { for c in list { c.cancel() }; list = [] } }
    var count: Int { lock.withLock { list.count } }
}
#endif
