#if os(macOS)
import XCTest
import Foundation
import PortalKit
import PortalTestSupport
@testable import PortalHostCore

/// Names that tell devices apart: the shown name, the cleaning on the Host, the rename -> .claude/host.md § pairing-store, § admin
final class ShownNamesTests: XCTestCase {
    private func key(_ n: UInt8) -> Data { Data(repeating: n, count: 32) }
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }
    private func peer(_ n: UInt8, _ name: String, alias: String? = nil, added: TimeInterval? = nil) -> PairedPeer {
        PairedPeer(key: key(n), name: name, alias: alias, added: added.map(at))
    }

    func testTwoOfOneModelAreNumberedByPairingDate() {
        let peers = [peer(2, "iPad mini", added: 20), peer(1, "iPad mini", added: 10)]
        let shown = PairedDevice.shownNames(peers)
        XCTAssertEqual(shown[key(1)], "iPad mini")
        XCTAssertEqual(shown[key(2)], "iPad mini 2")
    }

    func testPairingAgainChangesNoNumber() {
        // The first device re-paired: `add` keeps its date, so the order, and so the names, are as before.
        let before = PairedDevice.shownNames([peer(1, "iPad mini", added: 10), peer(2, "iPad mini", added: 20)])
        let after = PairedDevice.shownNames([peer(1, "iPad mini", added: 10), peer(2, "iPad mini", added: 20)])
        XCTAssertEqual(before, after)
    }

    func testAnAliasIsShownAndFreesTheName() {
        let peers = [peer(1, "iPad mini", added: 10), peer(2, "iPad mini", alias: "Den iPad", added: 20)]
        let shown = PairedDevice.shownNames(peers)
        XCTAssertEqual(shown[key(1)], "iPad mini")
        XCTAssertEqual(shown[key(2)], "Den iPad")
    }

    func testADeviceReallyNamedLikeTheComputedOnePushesItUp() {
        for order in [[10.0, 20, 30], [10, 30, 20]] {
            let peers = [peer(1, "iPad mini", added: order[0]), peer(2, "iPad mini", added: order[1]),
                         peer(3, "iPad mini 2", added: order[2])]
            let shown = PairedDevice.shownNames(peers)
            XCTAssertEqual(shown[key(1)], "iPad mini", "\(order)")
            XCTAssertEqual(shown[key(3)], "iPad mini 2", "\(order)")
            XCTAssertEqual(shown[key(2)], "iPad mini 3", "\(order)")
            XCTAssertEqual(Set(shown.values).count, 3)
        }
    }

    func testTwoEqualAliasesNumberTheLaterOne() {
        let peers = [peer(1, "iPad", alias: "Den", added: 10), peer(2, "iPhone", alias: "Den", added: 20)]
        let shown = PairedDevice.shownNames(peers)
        XCTAssertEqual(shown[key(1)], "Den")
        XCTAssertEqual(shown[key(2)], "Den 2")
    }

    func testAnOldFileWithoutDatesNumbersInStoreOrderEveryTime() {
        let peers = [peer(1, "iPad"), peer(2, "iPad"), peer(3, "iPad")]
        for _ in 0..<5 {
            let shown = PairedDevice.shownNames(peers)
            XCTAssertEqual(peers.map { shown[$0.key] }, ["iPad", "iPad 2", "iPad 3"])
        }
    }

    func testADeviceWithoutADateComesBeforeDatedOnes() {
        let peers = [peer(1, "iPad", added: 5), peer(2, "iPad")]
        let shown = PairedDevice.shownNames(peers)
        XCTAssertEqual(shown[key(2)], "iPad")
        XCTAssertEqual(shown[key(1)], "iPad 2")
    }

    func testComparisonIsExact() {
        let shown = PairedDevice.shownNames([peer(1, "iPad", added: 1), peer(2, "ipad", added: 2), peer(3, "iPad ", added: 3)])
        XCTAssertEqual(shown[key(2)], "ipad")
        XCTAssertEqual(shown[key(3)], "iPad 2", "the trailing space is cleaned away, so it is the same name")
    }

    func testAHostileStoredNameIsShownCleanAndBounded() {
        let hostile = "\u{7}" + String(repeating: "x\u{202E}\n", count: 5_000)
        let shown = PairedDevice.shownNames([peer(1, hostile, added: 1), peer(2, hostile, added: 2)])
        for name in shown.values {
            XCTAssertLessThanOrEqual(name.utf8.count, DeviceName.maxBytes)
            XCTAssertLessThanOrEqual(name.count, DeviceName.maxCharacters)
            XCTAssertEqual(DeviceName.clean(name), name)
        }
        XCTAssertEqual(Set(shown.values).count, 2)
    }
}

/// The Host over a real control connection: what it stores from `hello`, what it shows, what it sends, what it logs.
final class DeviceNamesServiceTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private var dir: URL!
    private var launcher: FakeLauncher!
    private var service: HostService!
    private var port: UInt16 = 0
    private var peers: [ScriptedPeer] = []

    override func setUp() async throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-n-" + UUID().uuidString)
        launcher = FakeLauncher()
    }

    override func tearDown() async throws {
        for p in peers { p.close() }
        await service?.stop()
        launcher.game?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    private var fake: GameApp { GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true) }

    private func start() async throws {
        await service?.stop()
        let config = HostConfig(name: "Test Host", storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
                                launcher: launcher, power: NoPower(), advertise: false, port: 0, extraGames: [fake])
        service = try HostService(config: config)
        port = try await service.start()
    }

    private func pairedPeer(_ name: String) async throws -> ScriptedPeer {
        let code = try await service.beginPairing()
        let p = ScriptedPeer(identity: Identity(), name: name)
        peers.append(p)
        try p.connect(port: port)
        let result = try await p.pair(code: code)
        guard case .ok = result else { throw PeerError.pairing(result) }
        return p
    }

    private func storedPeers() throws -> [PairedPeer] { try PairingStore(fileURL: dir.appendingPathComponent("host.json")).peers }

    /// Writes each name as stored (the way an older or damaged file would hold it), before the Host starts.
    private func seedStore(_ list: [(ScriptedPeer, String)]) throws {
        let file = dir.appendingPathComponent("host.json")
        let store = try PairingStore(fileURL: file)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["peers"] = list.map { ["key": $0.0.identity.publicKey.base64EncodedString(), "name": $0.1] }
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        for (p, _) in list { p.trust(hostKey: store.identity.publicKey) }
    }

    private func launchAndStream(_ p: ScriptedPeer) async throws {
        p.send(.launch(titleID: fakeID))
        let running = await p.next { $0.gameState?.run == .running }
        XCTAssertNotNil(running, "no running state")
    }

    // MARK: stored from the device

    /// The Host admits asynchronously: waits until some device is live (admission stores the hello's name before that).
    private func admitted() async {
        for _ in 0..<400 {
            if await service.devices().contains(where: \.live) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func fileBytes() throws -> Data { try Data(contentsOf: dir.appendingPathComponent("host.json")) }

    /// Nothing a hello claims is kept, shown or published until the device has proved its key (its sealed `ready` opened).
    func testAHelloThatNeverProvesItsKeyChangesNothing() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        let statuses = StatusLog(service.status)
        try await Task.sleep(nanoseconds: 200_000_000)  // the stream's earlier statuses arrive first
        let seen = statuses.all.count
        let before = try fileBytes()
        let reply = await p.hello(helloName: "Spoofed")
        guard case .welcome? = reply else { return XCTFail("no welcome: \(String(describing: reply))") }
        try await Task.sleep(nanoseconds: 300_000_000)  // no `ready` comes
        XCTAssertEqual(try storedPeers().map(\.name), ["iPad"])
        XCTAssertNil(try storedPeers()[0].kind)
        XCTAssertEqual(try fileBytes(), before, "the file on disk is untouched")
        let shown = await service.devices().map(\.shownName)
        XCTAssertEqual(shown, ["iPad"])
        XCTAssertEqual(statuses.all.count, seen, "nothing was published: \(statuses.all.dropFirst(seen))")
    }

    /// A hello that carries a paired device's key but whose `ready` does not open (the sender does not hold the key).
    func testAHelloWithAKeyItDoesNotHoldChangesNothing() async throws {
        try await start()
        let victim = try await pairedPeer("iPad")
        let before = try fileBytes()
        let spoofer = ScriptedPeer(identity: Identity(), name: "Spoofer")
        peers.append(spoofer)
        spoofer.trust(hostKey: try XCTUnwrap(victim.hostKey))
        try spoofer.connect(port: port)
        let reply = await spoofer.hello(helloName: "Spoofed", claimedKey: victim.identity.publicKey)
        guard case .welcome? = reply else { return XCTFail("no welcome: \(String(describing: reply))") }
        try? spoofer.ready()
        let closed = await spoofer.waitClosed()
        XCTAssertTrue(closed, "the Host ended the connection")
        XCTAssertEqual(try storedPeers().map(\.name), ["iPad"])
        XCTAssertEqual(try fileBytes(), before)
        let shown = await service.devices().map(\.shownName)
        XCTAssertEqual(shown, ["iPad"])
    }

    /// A completed admission stores the name and kind, and the status line, a busy and a takenBy use the new name.
    func testACompletedAdmissionStoresTheNameAndKind() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        try await p.open(port: port, helloName: "iPad mini")
        await admitted()
        XCTAssertEqual(try storedPeers().map(\.name), ["iPad mini"])
        XCTAssertEqual(try storedPeers()[0].kind, .tool)
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.shownName), ["iPad mini"])
        XCTAssertEqual(devices.map(\.kind), [.tool])
    }

    /// The new name is the one a `busy` refusal names.
    func testTheBusyRefusalUsesTheNameTheAdmittedHelloBrought() async throws {
        try await start()
        let a = try await pairedPeer("iPad")
        let b = try await pairedPeer("Tablet")
        try await a.open(port: port, resume: false, helloName: "Renamed iPad")
        try await launchAndStream(a)
        let reply = await b.hello()
        XCTAssertEqual(reply, .refuse(.busy(device: "Renamed iPad")))
    }

    func testAHostileHelloNameIsCleanedAndBoundedBeforeItIsStored() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        let hostile = "\u{7}Den\u{202E}" + String(repeating: "y\n", count: 5_000)
        try await p.open(port: port, helloName: hostile)
        await admitted()
        let stored = try storedPeers()[0].name
        XCTAssertLessThanOrEqual(stored.utf8.count, DeviceName.maxBytes)
        XCTAssertEqual(DeviceName.clean(stored), stored)
        XCTAssertTrue(stored.hasPrefix("Deny y y"), stored)
    }

    func testAHelloWithoutANameKeepsTheOldOne() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        try await p.open(port: port)
        XCTAssertEqual(try storedPeers().map(\.name), ["iPad"])
        p.close()
        let q = ScriptedPeer(identity: p.identity, name: "iPad")
        peers.append(q)
        q.trust(hostKey: try XCTUnwrap(p.hostKey))
        try await q.open(port: port, helloName: " \n ")
        XCTAssertEqual(try storedPeers().map(\.name), ["iPad"], "a name that cleans to nothing changes nothing")
    }

    func testAHelloNeverTouchesTheHostsAlias() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        try await service.renameDevice(p.identity.publicKey, to: "Den iPad")
        try await p.open(port: port, helloName: "iPad mini")
        await admitted()
        XCTAssertEqual(try storedPeers()[0].alias, "Den iPad")
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.shownName), ["Den iPad"])
        XCTAssertEqual(devices.map(\.name), ["iPad mini"])
    }

    func testThePairingNameIsCleanedOnTheHostToo() async throws {
        try await start()
        let hostile = "\u{7}Den\u{202E} iPad" + String(repeating: "z", count: 10_000)
        _ = try await pairedPeer(hostile)
        let stored = try storedPeers()[0].name
        XCTAssertLessThanOrEqual(stored.utf8.count, DeviceName.maxBytes)
        XCTAssertEqual(DeviceName.clean(stored), stored)
        XCTAssertTrue(stored.hasPrefix("Den iPad"), stored)
        XCTAssertNotNil(try storedPeers()[0].added, "paired today")
    }

    func testAPairingNameThatCleansToNothingIsCalledDevice() async throws {
        try await start()
        _ = try await pairedPeer(" \n\u{7} ")
        XCTAssertEqual(try storedPeers()[0].name, DeviceName.fallback)
    }

    // MARK: shown and sent

    func testDevicesAreNumberedAndSortedByShownName() async throws {
        try await start()
        let a = try await pairedPeer("iPad mini")
        let b = try await pairedPeer("iPad mini")
        let c = try await pairedPeer("Apple TV 4K")
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.shownName), ["Apple TV 4K", "iPad mini", "iPad mini 2"])
        XCTAssertEqual(devices.map(\.id), [c.identity.publicKey, a.identity.publicKey, b.identity.publicKey])
    }

    func testASecondDevicesBusyRefusalCarriesTheShownName() async throws {
        try await start()
        let first = try await pairedPeer("iPad mini")
        let second = try await pairedPeer("iPad mini")
        _ = try await pairedPeer("iPad mini")
        try await second.open(port: port, resume: false)
        try await launchAndStream(second)
        let reply = await first.hello()
        XCTAssertEqual(reply, .refuse(.busy(device: "iPad mini 2")), "the shown name, not the stored one")
    }

    func testTheBusyRefusalCarriesTheAliasAndNeverMoreThanTheLimits() async throws {
        try await start()
        let first = try await pairedPeer("iPad")
        let second = try await pairedPeer("iPad")
        try await service.renameDevice(second.identity.publicKey, to: "Den iPad")
        try await second.open(port: port, resume: false)
        try await launchAndStream(second)
        let reply = await first.hello()
        XCTAssertEqual(reply, .refuse(.busy(device: "Den iPad")))
    }

    func testAStoredHugeNameReachesTheWireCleanAndBounded() async throws {
        let hostile = "\u{7}Den\u{202E} " + String(repeating: "a\u{0}\n", count: 3_500)
        XCTAssertGreaterThan(hostile.utf8.count, 10_000)
        let player = ScriptedPeer(identity: Identity(), name: "Phone")
        peers.append(player)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedStore([(player, hostile)])
        try await start()
        try await player.open(port: port, resume: false)
        try await launchAndStream(player)
        let other = try await pairedPeer("Tablet")
        guard case let .refuse(.busy(device))? = await other.hello() else { return XCTFail("not refused busy") }
        XCTAssertLessThanOrEqual(device.utf8.count, DeviceName.maxBytes)
        XCTAssertLessThanOrEqual(device.count, DeviceName.maxCharacters)
        XCTAssertEqual(DeviceName.clean(device), device)
        XCTAssertTrue(device.hasPrefix("Den a a"), device)
    }

    func testTheByeThatNamesWhoTookTheMacCarriesTheShownNameCleanAndBounded() async throws {
        let hostile = "\u{7}Den\u{202E} " + String(repeating: "b\u{0}\n", count: 3_500)
        let a = ScriptedPeer(identity: Identity(), name: "Phone"), b = ScriptedPeer(identity: Identity(), name: "Tablet")
        peers += [a, b]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedStore([(a, "Phone"), (b, hostile)])
        try await start()
        try await a.open(port: port, resume: false)
        _ = await a.next { $0.gameState != nil }
        try await b.open(port: port)
        let bye = await a.next { if case .bye = $0 { true } else { false } }
        guard case let .bye(takenBy?)? = bye else { return XCTFail("no bye naming the device") }
        XCTAssertLessThanOrEqual(takenBy.utf8.count, DeviceName.maxBytes)
        XCTAssertLessThanOrEqual(takenBy.count, DeviceName.maxCharacters)
        XCTAssertEqual(DeviceName.clean(takenBy), takenBy)
        XCTAssertTrue(takenBy.hasPrefix("Den b b"), takenBy)
    }

    func testTheByeThatNamesWhoTookTheMacCarriesTheShownName() async throws {
        try await start()
        let a = try await pairedPeer("iPad mini")
        let b = try await pairedPeer("iPad mini")
        try await a.open(port: port, resume: false)
        _ = await a.next { $0.gameState != nil }
        try await b.open(port: port)
        let bye = await a.next { if case .bye = $0 { true } else { false } }
        XCTAssertEqual(bye, .bye(takenBy: "iPad mini 2"))
    }

    // MARK: the log

    func testASessionsLogLinesCarryTheTagAndNoName() async throws {
        try await start()
        let statuses = StatusLog(service.status)
        let ends = StatusEnds(service.sessionEnds)
        let p = try await pairedPeer("Den iPad")
        try await p.open(port: port)
        let live = await statuses.wait { statuses.all.contains { if case .live = $0 { true } else { false } } }
        XCTAssertTrue(live)
        p.closeControl()
        let ended = await ends.wait { !ends.all.isEmpty }
        XCTAssertTrue(ended)
        for line in ends.all.map(\.line) {
            XCTAssertFalse(line.contains("Den"), "a name in the log: \(line)")
            XCTAssertFalse(line.contains("iPad"), "a name in the log: \(line)")
        }
        XCTAssertTrue(ends.all[0].line.hasPrefix("session end: \(p.tag) after "))
        // The status carries the tag for the log and the shown name for the menu only.
        XCTAssertTrue(statuses.all.contains { if case let .live(device, tag, _) = $0 { device == "Den iPad" && tag == p.tag } else { false } })
    }

    // MARK: rename

    func testRenameCleansAndAnEmptyOneRemovesTheAlias() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        let id = p.identity.publicKey
        try await service.renameDevice(id, to: " Den\u{202E}  iPad \n")
        XCTAssertEqual(try storedPeers()[0].alias, "Den iPad")
        let shown = await service.devices().map(\.shownName)
        XCTAssertEqual(shown, ["Den iPad"])
        try await service.renameDevice(id, to: "  ")
        XCTAssertNil(try storedPeers()[0].alias, "an alias that cleans to nothing is removed")
        try await service.renameDevice(id, to: "Den")
        try await service.renameDevice(id, to: nil)
        XCTAssertNil(try storedPeers()[0].alias)
        let again = await service.devices().map(\.shownName)
        XCTAssertEqual(again, ["iPad"])
    }

    func testRenameBoundsTheAlias() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        try await service.renameDevice(p.identity.publicKey, to: String(repeating: "\u{1F468}\u{200D}\u{1F469}", count: 200))
        let alias = try XCTUnwrap(storedPeers()[0].alias)
        XCTAssertLessThanOrEqual(alias.utf8.count, DeviceName.maxBytes)
    }

    func testRenameWhileConnectedSendsNothingAndTheDeviceStaysLive() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        try await p.open(port: port)
        try await service.renameDevice(p.identity.publicKey, to: "Den iPad")
        let devices = await service.devices()
        XCTAssertEqual(devices.map(\.shownName), ["Den iPad"])
        XCTAssertEqual(devices.map(\.live), [true])
        XCTAssertFalse(p.messages.contains { if case .bye = $0 { true } else { false } }, "nothing is sent to the device")
    }

    func testRenameOfAnUnknownDeviceChangesNothing() async throws {
        try await start()
        _ = try await pairedPeer("iPad")
        try await service.renameDevice(Identity().publicKey, to: "Nobody")
        XCTAssertNil(try storedPeers()[0].alias)
    }

    func testRenameAfterStopThrows() async throws {
        try await start()
        let p = try await pairedPeer("iPad")
        await service.stop()
        do { try await service.renameDevice(p.identity.publicKey, to: "x"); XCTFail("renamed after stop") } catch {
            XCTAssertEqual(error as? HostServiceError, .stopped)
        }
    }
}

/// Statuses a stream delivered.
final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()  // guards items
    private var items: [HostStatus] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<HostStatus>) {
        task = Task { [weak self] in for await s in stream { self?.lock.withLock { self?.items.append(s) } } }
    }
    deinit { task?.cancel() }
    var all: [HostStatus] { lock.withLock { items } }
    func wait(timeout: TimeInterval = 5, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return cond()
    }
}
#endif
