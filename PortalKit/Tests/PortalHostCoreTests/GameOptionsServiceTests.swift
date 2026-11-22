#if os(macOS)
import XCTest
import Foundation
import PortalKit
import PortalTestSupport
@_spi(Testing) @testable import PortalHostCore

/// The Host's side of per-game options over a real control connection: a generated app with its own `launcher.json`, a made-up
/// bundle ID and a folder under the temporary one; nothing of the person's is read or written.
final class GameOptionsServiceTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private let bundleID = "test.nxportal.options"
    private var dir: URL!
    private var optionsFile: URL { dir.appendingPathComponent("support/options.json") }
    private var launcher: FakeLauncher!
    private var service: HostService!
    private var port: UInt16 = 0
    private var peers: [ScriptedPeer] = []
    private var saved: [String: String] = [:]

    override func setUp() async throws {
        continueAfterFailure = true
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-o-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        launcher = FakeLauncher()
        try await start()
    }

    override func tearDown() async throws {
        for p in peers { p.close() }
        await service.stop()
        launcher.game?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// (Re)starts the service on a generated app holding `rows` (nil: no `launcher.json`).
    private func start(rows: [[String: Any]]? = OptionsFixture.five, fileVariables: [String: String] = [:],
                       savedChoice: (@Sendable (String, String) -> String?)? = nil, strict: Bool = false) async throws {
        if service != nil { await service.stop() }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("Fake.app"))
        let app = try OptionsFixture.bundle(in: dir, rows: rows)
        let game = GameApp(titleID: fakeID, name: "Fake Game", url: app, streamable: true, bundleID: bundleID)
        var config = HostConfig(name: "Test Host", storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [], launcher: launcher,
                                power: RecordingPower(), advertise: false, port: 0, extraGames: [game])
        config.silenceTimeout = 3
        config.optionsURL = optionsFile
        let domain = bundleID, fromApp = saved
        config.savedChoice = savedChoice ?? { id, env in id == domain ? fromApp[env] : nil }
        config.gameEnvironment = { _ in fileVariables }
        if !strict { config.settableOption = { _ in true } }  // made-up variables; `strict` = the real allow-list
        service = try HostService(config: config)
        port = try await service.start()
    }

    private func livePeer(_ name: String = "Test iPad", resume: Bool? = nil) async throws -> ScriptedPeer {
        let code = try await service.beginPairing()
        let p = ScriptedPeer(identity: Identity(), name: name)
        peers.append(p)
        try p.connect(port: port)
        let result = try await p.pair(code: code)
        guard case .ok = result else { throw PeerError.pairing(result) }
        try await p.open(port: port, resume: resume)
        return p
    }

    /// The next `options` reply after `mark` messages.
    private func options(_ p: ScriptedPeer, after mark: Int? = nil, timeout: TimeInterval = 3) async -> GameOptions? {
        let start = mark ?? p.messages.count
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            for m in p.messages.dropFirst(start) { if case let .options(o) = m { return o } }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    private func ask(_ p: ScriptedPeer, _ m: ControlMessage) async -> GameOptions? {
        let mark = p.messages.count
        p.send(m)
        return await options(p, after: mark)
    }

    private func setting(_ o: GameOptions?, _ env: String) -> OptionSetting? { o?.settings.first { $0.env == env } }

    private func storeChoices() -> [String: String] { GameOptionsStore(fileURL: optionsFile).choices(titleID: fakeID) }

    // MARK: listing

    func testTheRequestAnswersTheGamesFiveSettingsAtTheirDefaults() async throws {
        let p = try await livePeer()
        let o = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(o?.titleID, fakeID)
        XCTAssertEqual(o?.settings.map(\.env), ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD", "DM_DIAL", "DM_FPS_FLOOR"])
        XCTAssertNil(o?.rejected)
        for s in o?.settings ?? [] { XCTAssertEqual(s.current, s.defaultValue, s.env); XCTAssertFalse(s.chosen, s.env) }
        XCTAssertEqual(setting(o, "DM_RENDER_SCALE")?.base?.docked, .init(width: 1920, height: 1080))
        XCTAssertEqual(setting(o, "DM_DIAL")?.kind, "dial", "a kind this build does not know is listed, never dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: optionsFile.path), "a request writes nothing")
    }

    func testALibrarySessionGetsThemToo() async throws {
        let p = try await livePeer(resume: false)
        let o = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(o?.settings.count, 5)
        let set = await ask(p, .setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: "30"))
        XCTAssertEqual(setting(set, "DM_FPS_TARGET")?.current, "30")
    }

    func testNoListMeansNoSettings() async throws {
        try await start(rows: nil)
        let p = try await livePeer()
        let o = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(o, GameOptions(titleID: fakeID, settings: [], rejected: nil))
    }

    func testAnUnknownTitleIsAnEmptyAnswerAndTouchesNothing() async throws {
        let p = try await livePeer()
        let o = await ask(p, .optionsRequest(titleID: "0000000000000099"))
        XCTAssertEqual(o, GameOptions(titleID: "0000000000000099", settings: [], rejected: nil))
        let set = await ask(p, .setOption(titleID: "0000000000000099", env: "DM_FPS_TARGET", value: "30"))
        XCTAssertEqual(set?.rejected, "DM_FPS_TARGET")
        XCTAssertFalse(FileManager.default.fileExists(atPath: optionsFile.path), "nothing is kept for a game the Mac does not have")
    }

    /// The app's own saved choice is what the game would use at a start from Finder: shown while the person has none here.
    func testTheAppsSavedChoiceShowsWhenItValidatesAndTheDefaultWhenItDoesNot() async throws {
        saved = ["DM_RENDER_SCALE": "0.6", "DM_FPS_TARGET": "99"]
        try await start()
        let p = try await livePeer()
        let o = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(setting(o, "DM_RENDER_SCALE")?.current, "0.6")
        XCTAssertEqual(setting(o, "DM_RENDER_SCALE")?.chosen, false, "it is not this app's choice")
        XCTAssertEqual(setting(o, "DM_FPS_TARGET")?.current, "60", "a saved value the list does not offer is not shown")
    }

    // MARK: setting

    func testASetThenAnAnswerWithTheNewValueAndTheChoiceKept() async throws {
        let p = try await livePeer()
        let o = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "0.76"))
        let s = setting(o, "DM_RENDER_SCALE")
        XCTAssertEqual(s?.current, "0.75", "snapped to the step")
        XCTAssertEqual(s?.chosen, true)
        XCTAssertNil(o?.rejected)
        XCTAssertEqual(storeChoices(), ["DM_RENDER_SCALE": "0.75"])
        XCTAssertEqual(setting(o, "DM_FPS_TARGET")?.chosen, false)
    }

    func testAValueTheGameDoesNotOfferOrAVariableItDoesNotHaveIsRefusedAndNothingChanges() async throws {
        let p = try await livePeer()
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "0.75"))
        let tooHigh = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "1.5"))
        XCTAssertEqual(tooHigh?.rejected, "DM_RENDER_SCALE")
        XCTAssertEqual(setting(tooHigh, "DM_RENDER_SCALE")?.current, "0.75", "unchanged")
        let unknown = await ask(p, .setOption(titleID: fakeID, env: "DM_NOT_IN_THE_LIST", value: "1"))
        XCTAssertEqual(unknown?.rejected, "DM_NOT_IN_THE_LIST")
        let dial = await ask(p, .setOption(titleID: fakeID, env: "DM_DIAL", value: "x"))
        XCTAssertEqual(dial?.rejected, "DM_DIAL", "a kind this build does not know cannot be set")
        let wrongKind = await ask(p, .setOption(titleID: fakeID, env: "DM_FPS_HOLD", value: "yes"))
        XCTAssertEqual(wrongKind?.rejected, "DM_FPS_HOLD")
        XCTAssertEqual(storeChoices(), ["DM_RENDER_SCALE": "0.75"])
    }

    func testTheHostsOwnVariablesAndHiddenOnesAreRefused() async throws {
        var rows = OptionsFixture.five
        rows.append(["env": "DM_FULLSCREEN", "kind": "choice", "section": "x", "label": "x", "note": "", "default": "0", "options": [["0", "a"], ["1", "b"]]])
        rows.append(["env": "DM_MIC", "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"])
        rows.append(["env": "DM_STREAM", "kind": "choice", "section": "x", "label": "x", "note": "", "default": "a", "options": [["a", "a"], ["/tmp/x", "b"]]])
        try await start(rows: rows)
        let p = try await livePeer()
        for env in ["DM_STREAM", "DM_LAUNCHER", "DM_FULLSCREEN", "DM_MIC"] {
            let o = await ask(p, .setOption(titleID: fakeID, env: env, value: env == "DM_STREAM" ? "/tmp/x" : "1"))
            XCTAssertEqual(o?.rejected, env)
            XCTAssertFalse(o?.settings.contains { $0.env == env } ?? true, "\(env) is not listed either")
        }
        XCTAssertEqual(storeChoices(), [:])
    }

    func testNoValueWithABreakOrAnEnvNameOfAShellIsTaken() async throws {
        let p = try await livePeer()
        for (env, value) in [("DM_FPS_TARGET", "30\n"), ("DM_FPS_TARGET", "30\u{0}"), ("DM_FPS_TARGET", "30; rm -rf /"), ("DM_RENDER_SCALE", "0.75\n"),
                             ("PATH", "/tmp"), ("DM_FPS_TARGET=30 X", "1"), ("DM_FPS_TARGET\n", "30"), ("DM_a", "1"), ("", "1")] {
            let o = await ask(p, .setOption(titleID: fakeID, env: env, value: value))
            XCTAssertNotNil(o?.rejected, "\(env.debugDescription) = \(value.debugDescription)")
            XCTAssertTrue(o?.rejected == env || o?.rejected == "", "the echo is the name, or empty when it is not a name: \(String(describing: o?.rejected))")
        }
        XCTAssertEqual(storeChoices(), [:])
    }

    /// What is over a limit on the wire is ignored: no answer, nothing kept, and the session goes on and answers the next one.
    func testWhatIsOverALimitIsIgnoredAndTheSessionGoesOn() async throws {
        let p = try await livePeer()
        for hostile: ControlMessage in [
            .setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: String(repeating: "1", count: 5_000)),
            .setOption(titleID: fakeID, env: String(repeating: "A", count: 100_000), value: "1"),
            .setOption(titleID: fakeID, env: "DM_" + String(repeating: "A", count: 62), value: "1"),
            .setOption(titleID: String(repeating: "T", count: 900_000), env: "DM_FPS_TARGET", value: "1"),
            .optionsRequest(titleID: "../../x"), .resetOptions(titleID: ""),
        ] {
            let mark = p.messages.count
            p.send(hostile)
            let answered = await options(p, after: mark, timeout: 0.4)
            XCTAssertNil(answered, "ignored")
        }
        XCTAssertFalse(p.isClosed, "a refused message does not end the session")
        let after = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(after?.settings.count, 5)
        XCTAssertEqual(storeChoices(), [:])
    }

    /// The stale choice of a row the list no longer has can be removed with `setOption(nil)`; it was never applied.
    func testAStaleChoiceCanBeRemovedWithoutItsRow() async throws {
        GameOptionsStore(fileURL: optionsFile).set("1", env: "DM_GONE_FROM_THE_LIST", titleID: fakeID)
        try await start()
        let p = try await livePeer()
        let o = await ask(p, .setOption(titleID: fakeID, env: "DM_GONE_FROM_THE_LIST", value: nil))
        XCTAssertNil(o?.rejected)
        XCTAssertEqual(storeChoices(), [:])
        let notAName = await ask(p, .setOption(titleID: fakeID, env: "PATH", value: nil))
        XCTAssertNotNil(notAName?.rejected, "only a variable name can be removed")
    }

    // MARK: the runtime's own variables

    func testAReservedVariableIsNeverSetOrLaunchedWithEvenFromAHandEditedFile() async throws {
        let store = GameOptionsStore(fileURL: optionsFile)
        for env in ["DM_STREAM_PREPARE", "DM_KEYS", "DM_ENV_FILE", "DM_LAUNCH_PARAM", "DM_GAMES_DIR", "DM_GPU_CAPTURE_DIR", "DM_EXEC_OUT"] { store.set("/tmp/x", env: env, titleID: fakeID) }
        store.set("30", env: "DM_FPS_TARGET", titleID: fakeID)
        // A list that names them too (a game that lists one: its row is dropped, so even a valid-looking value has no row).
        var rows = OptionsFixture.five
        rows += ["DM_STREAM_PREPARE", "DM_KEYS", "DM_ENV_FILE", "DM_LAUNCH_PARAM"].map { ["env": $0, "kind": "choice", "section": "x", "label": "x", "note": "", "default": "a", "options": [["a", "a"], ["/tmp/x", "b"]]] as [String: Any] }
        try await start(rows: rows)
        let p = try await livePeer()
        let o = await ask(p, .setOption(titleID: fakeID, env: "DM_KEYS", value: "/tmp/x"))
        XCTAssertEqual(o?.rejected, "DM_KEYS")
        p.send(.launch(titleID: fakeID))
        let started = await waitFor { self.launcher.environments.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(launcher.environments.last, ["DM_FPS_TARGET": "30"], "checked again at launch")
    }

    func testTheOwnersEnvironmentFileKeepsItsOwnVariablesButNeverTheHostsTwo() {
        XCTAssertEqual(HostService.launchEnvironment(file: ["DM_ENV_FILE": "/owner/env.txt", "DM_STREAM": "x", "DM_LAUNCHER": "1"], choices: [:]),
                       ["DM_ENV_FILE": "/owner/env.txt"], "the file is the owner's")
        XCTAssertEqual(HostService.launchEnvironment(file: [:], choices: ["DM_ENV_FILE": "/x", "DM_KEYS": "/x", "DM_STREAM_PREPARE": "1", "DM_FPS_TARGET": "30"]),
                       ["DM_FPS_TARGET": "30"], "a device's choice is not")
    }

    /// With the real allow-list: a game that lists the runtime's own variables next to its settings, a hand-edited store that
    /// holds them, and a device that asks to set them.
    func testOnlyThePlayerSettingsOfTheGamesListCanBeSetOrLaunched() async throws {
        let own = PlayerOptionsTests.notForADevice
        let rows = OptionsFixture.five.prefix(3) + own.map { ["env": $0, "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"] as [String: Any] }
        let store = GameOptionsStore(fileURL: optionsFile)
        for n in own { store.set("1", env: n, titleID: fakeID) }
        store.set("30", env: "DM_FPS_TARGET", titleID: fakeID)
        try await start(rows: Array(rows), strict: true)
        let p = try await livePeer()
        let o = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(o?.settings.map(\.env), ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD"], "no row for any of them")
        for n in own {
            let r = await ask(p, .setOption(titleID: fakeID, env: n, value: "1"))
            XCTAssertEqual(r?.rejected, n, n)
        }
        p.send(.launch(titleID: fakeID))
        let started = await waitFor { self.launcher.environments.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(launcher.environments.last, ["DM_FPS_TARGET": "30"])
    }

    /// The 65th game with a choice: the device is told the Mac's list is full (nothing is dropped silently).
    func testAGameOverTheStoresTitleLimitGetsTheFullAnswerAndKeepsEveryOtherChoice() async throws {
        let store = GameOptionsStore(fileURL: optionsFile)
        for i in 0..<GameOptionsStore.maxTitles { store.set("30", env: "DM_FPS_TARGET", titleID: "GAME\(i)") }
        try await start()
        let p = try await livePeer()
        let o = await ask(p, .setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: "30"))
        XCTAssertEqual(o?.rejected, "DM_FPS_TARGET")
        XCTAssertEqual(o?.full, true)
        XCTAssertEqual(storeChoices(), [:], "nothing was kept")
        XCTAssertEqual(GameOptionsStore(fileURL: optionsFile).choices(titleID: "GAME0"), ["DM_FPS_TARGET": "30"], "nobody else lost a choice")
        let again = await ask(p, .setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: "bad"))
        XCTAssertNil(again?.full, "a bad value is not 'full'")
    }

    /// `portal-hostd --fake --fake-options` serves `FakeArt.sampleOptions` as the game's `launcher.json`: with the real gate
    /// (no widening) every sample row is a row.
    func testTheTestToolsSampleListPassesTheRealGate() async throws {
        try await start(rows: FakeArt.sampleOptions, strict: true)
        let p = try await livePeer()
        let o = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(o?.settings.map(\.env), FakeArt.sampleOptions.map { $0["env"] as! String })
        XCTAssertEqual(o?.settings.count, 10)
        XCTAssertTrue(FakeArt.sampleOptions.allSatisfy { PlayerOptions.isSettable($0["env"] as! String) })
    }

    // MARK: the actor and the preferences

    /// Five rows at 0.25 s each of preference reading: the answer takes over a second, the video does not wait for it.
    func testASlowPreferenceReadDoesNotDelayVideo() async throws {
        try await start(savedChoice: { _, _ in Thread.sleep(forTimeInterval: 0.25); return nil })
        let p = try await livePeer()
        p.send(.launch(titleID: fakeID))
        _ = await p.next { $0.gameState?.run == .running }
        try await Task.sleep(nanoseconds: 500_000_000)
        let mark = p.messages.count
        p.send(.optionsRequest(titleID: fakeID))
        let before = p.received.count
        let t0 = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let frames = p.received.count - before
        XCTAssertGreaterThanOrEqual(frames, 40, "\(frames) frames in \(Date().timeIntervalSince(t0)) s while the preferences are read")
        let o = await options(p, after: mark, timeout: 3)
        XCTAssertEqual(o?.settings.count, 5)
    }

    /// The runtime ignores a saved choice that is not a string (`frontends.md` § Saved choices, "one string per setting"), so the
    /// Host shows only text: a number or a boolean is what a start would NOT use.
    func testASavedChoiceThatIsNotTextIsNotShown() async throws {
        XCTAssertEqual(HostConfig.preferenceText("30"), "30")
        XCTAssertNil(HostConfig.preferenceText(NSNumber(value: 30)))
        XCTAssertNil(HostConfig.preferenceText(NSNumber(value: true)))
        XCTAssertNil(HostConfig.preferenceText(["a": 1]))
        XCTAssertNil(HostConfig.preferenceText(Date()))
        // The real reader, on a domain nobody has: nothing, and nothing of anyone's is read.
        XCTAssertNil(HostConfig(name: "x", storeURL: dir, libraryRoots: [], launcher: launcher, power: RecordingPower(), advertise: false, port: 0)
            .savedChoice("test.nxportal.nobody.\(UUID().uuidString)", "DM_FPS_TARGET"))
    }

    func testRemovingAChoiceOrSettingTheDefaultLeavesNoChoice() async throws {
        let p = try await livePeer()
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "0.75"))
        let removed = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: nil))
        XCTAssertEqual(setting(removed, "DM_RENDER_SCALE")?.chosen, false)
        XCTAssertEqual(setting(removed, "DM_RENDER_SCALE")?.current, "1.0")
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "0.75"))
        let back = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "1.0"))
        XCTAssertEqual(setting(back, "DM_RENDER_SCALE")?.chosen, false, "the tested default is not a choice")
        XCTAssertEqual(storeChoices(), [:])
    }

    func testResetRemovesEveryChoiceOfTheGameOnly() async throws {
        GameOptionsStore(fileURL: optionsFile).set("1", env: "DM_OTHER", titleID: "0000000000000042")
        try await start()
        let p = try await livePeer()
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "0.75"))
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: "30"))
        let o = await ask(p, .resetOptions(titleID: fakeID))
        XCTAssertEqual(o?.settings.filter(\.chosen).count, 0)
        XCTAssertEqual(storeChoices(), [:])
        XCTAssertEqual(GameOptionsStore(fileURL: optionsFile).choices(titleID: "0000000000000042"), ["DM_OTHER": "1"])
    }

    func testAChoiceTheGameNoLongerOffersIsNeitherShownNorKept() async throws {
        let store = GameOptionsStore(fileURL: optionsFile)
        store.set("9", env: "DM_RENDER_SCALE", titleID: fakeID)
        store.set("1", env: "DM_GONE_FROM_THE_LIST", titleID: fakeID)
        store.set("30", env: "DM_FPS_TARGET", titleID: fakeID)
        try await start()  // the Host reads its file when it starts
        let p = try await livePeer()
        let o = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(setting(o, "DM_RENDER_SCALE")?.current, "1.0")
        XCTAssertEqual(setting(o, "DM_RENDER_SCALE")?.chosen, false)
        XCTAssertEqual(setting(o, "DM_FPS_TARGET")?.current, "30")
        p.send(.launch(titleID: fakeID))
        let started = await waitFor { self.launcher.environments.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(launcher.environments.last, ["DM_FPS_TARGET": "30"], "only what the list still offers reaches the game")
    }

    func testTheStoredChoicesAreBoundedByTheGamesOwnList() async throws {
        let p = try await livePeer()
        for i in 0..<300 { p.send(.setOption(titleID: fakeID, env: "DM_FLOOD_\(i)", value: "1")) }
        for env in ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD", "DM_FPS_FLOOR"] {
            p.send(.setOption(titleID: fakeID, env: env, value: ["DM_FPS_TARGET": "30", "DM_RENDER_SCALE": "0.5", "DM_FPS_HOLD": "off", "DM_FPS_FLOOR": "10"][env]!))
        }
        let end = Date().addingTimeInterval(5)
        while Date() < end, storeChoices().count < 4 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(storeChoices().count, 4)
        XCTAssertEqual(Set(storeChoices().keys), ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD", "DM_FPS_FLOOR"])
    }

    func testAnOverLongTitleOrNothingIsAnsweredAtAll() async throws {
        let p = try await livePeer()
        let mark = p.messages.count
        p.send(.optionsRequest(titleID: String(repeating: "T", count: 65)))
        p.send(.setOption(titleID: String(repeating: "T", count: 65), env: "DM_FPS_TARGET", value: "30"))
        p.send(.resetOptions(titleID: String(repeating: "T", count: 65)))
        let after = await ask(p, .optionsRequest(titleID: fakeID))
        XCTAssertEqual(after?.titleID, fakeID, "the first answer is the one for the title that fits")
        XCTAssertEqual(p.messages.dropFirst(mark).filter { if case .options = $0 { true } else { false } }.count, 1)
    }

    func testTheFileIsPrivateInAPrivateFolder() async throws {
        let p = try await livePeer()
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: "30"))
        func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        XCTAssertEqual(mode(optionsFile), 0o600)
        XCTAssertEqual(mode(optionsFile.deletingLastPathComponent()), 0o700)
    }

    func testAnUnadmittedConnectionIsNotAnswered() async throws {
        let code = try await service.beginPairing()
        let p = ScriptedPeer(identity: Identity(), name: "Test iPad")
        peers.append(p)
        try p.connect(port: port)
        _ = try await p.pair(code: code)
        guard case .welcome? = await p.hello() else { return XCTFail("no welcome") }  // welcomed, `ready` not sent
        p.send(.setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: "30"))
        let closed = await p.waitClosed()
        XCTAssertTrue(closed, "anything but `ready` ends a welcomed connection")
        XCTAssertFalse(p.messages.contains { if case .options = $0 { true } else { false } })
        XCTAssertEqual(storeChoices(), [:])
    }

    // MARK: applying

    func testALaunchGetsExactlyTheChoicesAsEnvironment() async throws {
        let p = try await livePeer()
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "0.75"))
        p.send(.launch(titleID: fakeID))
        let started = await waitFor { self.launcher.environments.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(launcher.environments.last, ["DM_RENDER_SCALE": "0.75"])
    }

    func testNoChoicesMeansNoVariables() async throws {
        let p = try await livePeer()
        p.send(.launch(titleID: fakeID))
        let started = await waitFor { self.launcher.environments.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(launcher.environments.last, [:])
    }

    func testTheChoicesGoOverTheHostWideFileAndTheHostsOwnStayTheHosts() async throws {
        try await start(fileVariables: ["DM_FPS_TARGET": "60", "X": "1", "DM_STREAM": "/elsewhere", "DM_LAUNCHER": "1"])
        let p = try await livePeer()
        _ = await ask(p, .setOption(titleID: fakeID, env: "DM_FPS_TARGET", value: "30"))
        p.send(.launch(titleID: fakeID))
        let started = await waitFor { self.launcher.environments.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(launcher.environments.last, ["DM_FPS_TARGET": "30", "X": "1"])
    }

    func testAChangeWhileTheGameRunsTouchesOnlyTheStore() async throws {
        let p = try await livePeer()
        p.send(.launch(titleID: fakeID))
        let started = await waitFor { self.launcher.environments.count == 1 && self.launcher.game != nil }
        XCTAssertTrue(started)
        let game = try XCTUnwrap(launcher.game)
        _ = await p.next { $0.gameState?.run == .running }
        try await Task.sleep(nanoseconds: 300_000_000)
        // What the Host tells a game about the session (pads and acknowledgements flow on their own).
        func told() -> Int {
            game.received.filter {
                switch $0 { case .config, .keyframe, .refresh, .pause, .quit, .players: true; default: false }
            }.count
        }
        let before = told()
        let o = await ask(p, .setOption(titleID: fakeID, env: "DM_RENDER_SCALE", value: "0.5"))
        XCTAssertEqual(setting(o, "DM_RENDER_SCALE")?.current, "0.5")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(told(), before, "the game is told nothing")
        XCTAssertEqual(launcher.environments.count, 1, "and is not started again")
        XCTAssertEqual(storeChoices(), ["DM_RENDER_SCALE": "0.5"])
    }

    // MARK: merge

    func testTheMergeRule() {
        XCTAssertEqual(HostService.launchEnvironment(file: ["DM_FPS_TARGET": "30", "X": "1"], choices: ["DM_FPS_TARGET": "60"]),
                       ["DM_FPS_TARGET": "60", "X": "1"])
        XCTAssertEqual(HostService.launchEnvironment(file: [:], choices: [:]), [:])
        XCTAssertEqual(HostService.launchEnvironment(file: ["A": "1"], choices: [:]), ["A": "1"])
        let merged = HostService.launchEnvironment(file: ["DM_STREAM": "/x", "DM_LAUNCHER": "1", "Y": "2"],
                                                   choices: ["DM_STREAM": "/y", "DM_LAUNCHER": "2", "DM_Z": "3"], allowing: { _ in true })
        XCTAssertEqual(merged, ["Y": "2", "DM_Z": "3"], "neither the file nor a choice can set the Host's own")
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return cond()
    }
}
#endif
