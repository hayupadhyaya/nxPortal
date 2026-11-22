#if os(macOS)
import XCTest
import Foundation
import PortalKit
import PortalTestSupport
@testable import PortalHostCore

/// What the Host collected from `sessionEnds`.
final class EndLog: @unchecked Sendable {
    private let lock = NSLock()  // guards list
    private var list: [SessionEndReport] = []
    func add(_ r: SessionEndReport) { lock.withLock { list.append(r) } }
    var all: [SessionEndReport] { lock.withLock { list } }
}

extension HostService {
    /// Test hook: the Host cancels the live session's control connection itself.
    func cancelLiveControl() { if let id = liveLink { links[id]?.connection.cancel() } }
}

/// The Host says why each live session ended, in one line -> .claude/host.md § session-end
final class SessionEndTests: XCTestCase {
    private var dir: URL!
    private var launcher: FakeLauncher!
    private var service: HostService!
    private var port: UInt16 = 0
    private var peers: [ScriptedPeer] = []
    private let ends = EndLog()
    private var reader: Task<Void, Never>?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-e-" + UUID().uuidString)
        launcher = FakeLauncher()
        var config = HostConfig(name: "Test Host", storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
                                launcher: launcher, power: NoPower(), advertise: false, port: 0)
        config.silenceTimeout = 1  // the client-silent case; the default is 10 s
        service = try HostService(config: config)
        port = try await service.start()
        let stream = service.sessionEnds, ends = ends
        reader = Task { for await r in stream { ends.add(r) } }
    }

    override func tearDown() async throws {
        for p in peers { p.close() }
        await service.stop()
        reader?.cancel()
        launcher.game?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    // MARK: the line

    /// The whole line, field by field, for a session that streamed and was closed by the device.
    func testTheLineSaysWhoEndedTheSessionAndWhatCrossedTheMediaPath() async throws {
        let p = try await livePeer("Phone")
        let pongs = await p.wait { p.pongCount >= 3 }
        XCTAssertTrue(pongs)
        p.closeControl()
        let r = try await end()
        XCTAssertEqual(r.device, p.tag, "a session end names the device by its tag")
        XCTAssertEqual(r.cause, .clientClosed)
        XCTAssertGreaterThanOrEqual(r.datagramsIn, 3)
        XCTAssertGreaterThanOrEqual(r.datagramsOut, 3)
        XCTAssertEqual(r.sendFailures, 0)
        XCTAssertNotNil(r.firstDatagramMs)
        XCTAssertEqual(r.mediaAddress, .same)
        let line = r.line
        XCTAssertTrue(line.hasPrefix("session end: \(p.tag) after "), line)
        XCTAssertFalse(line.contains("Phone"), "no device name in the line: \(line)")
        XCTAssertTrue(line.contains(" s, by client-closed, datagrams in \(r.datagramsIn) out \(r.datagramsOut), send failures 0, first datagram after "), line)
        XCTAssertTrue(line.hasSuffix(" ms, media local address same from control"), line)
        XCTAssertFalse(line.contains("127.0.0.1"), "no addresses in the line: \(line)")
    }

    /// A session whose device never sent a datagram: `never`, and nothing to compare the control address with.
    func testASessionWithoutADatagramSaysNever() async throws {
        let p = try await pairedPeer("Phone")
        guard case .welcome? = await p.hello() else { return XCTFail("no welcome") }
        p.send(.ready)  // no media socket, no ping
        _ = await p.next { $0.gameState != nil }
        p.closeControl()
        let r = try await end()
        XCTAssertNil(r.firstDatagramMs)
        XCTAssertEqual(r.datagramsIn, 0)
        XCTAssertEqual(r.mediaAddress, .unknown)
        XCTAssertTrue(r.line.contains("datagrams in 0 out 0, send failures 0, first datagram after never, media local address unknown"), r.line)
    }

    // MARK: each cause

    func testByClientClosedForABye() async throws {
        let p = try await livePeer("Phone")
        p.send(.bye())
        let r = try await end()
        XCTAssertEqual(r.cause, .clientClosed)
    }

    func testByClientSilent() async throws {
        let p = try await livePeer("Phone")
        _ = await p.wait { p.pongCount >= 1 }
        p.setSilent(true)
        let r = try await end(timeout: 4)
        XCTAssertEqual(r.cause, .clientSilent)
        XCTAssertTrue(r.line.contains(" by client-silent, "), r.line)
    }

    func testByHostStop() async throws {
        _ = try await livePeer("Phone")
        await service.stop()
        let r = try await end()
        XCTAssertEqual(r.cause, .hostStop)
    }

    func testByReplaced() async throws {
        let a = try await livePeer("Phone")
        let again = ScriptedPeer(identity: a.identity, name: "Phone")
        if let key = a.hostKey { again.trust(hostKey: key) }
        peers.append(again)
        try await again.open(port: port)
        let r = try await end()
        XCTAssertEqual(r.cause, .replaced)
        XCTAssertEqual(ends.all.count, 1, "the new session is still live")
    }

    func testByControlError() async throws {
        let p = try await livePeer("Phone")
        p.sendClearFrame(.listRequest)  // unsealed after welcome: does not open
        let r = try await end()
        XCTAssertEqual(r.cause, .controlError)
    }

    /// A reset (the receive fails) is an error, not the device closing; the media address still compares.
    func testAResetControlConnectionEndsByControlError() async throws {
        let p = try await livePeer("Phone")
        _ = await p.wait { p.pongCount >= 1 }
        await p.resetControl()
        let r = try await end()
        XCTAssertEqual(r.cause, .controlError)
        XCTAssertEqual(r.mediaAddress, .same)
    }

    /// A clean close by the device is `client-closed`, and the media address still compares (captured when live).
    func testACleanCloseIsClientClosedWithTheMediaAddressCompared() async throws {
        let p = try await livePeer("Phone")
        _ = await p.wait { p.pongCount >= 1 }
        p.closeControl()
        let r = try await end()
        XCTAssertEqual(r.cause, .clientClosed)
        XCTAssertEqual(r.mediaAddress, .same)
    }

    /// The Host ends the control connection itself (it has no path afterwards): the line still compares addresses.
    func testAHostSideCancelStillComparesTheMediaAddress() async throws {
        let p = try await livePeer("Phone")
        _ = await p.wait { p.pongCount >= 1 }
        await service.cancelLiveControl()
        let r = try await end()
        XCTAssertEqual(r.mediaAddress, .same, r.line)
    }

    /// A connection that never became live says nothing.
    func testAConnectionThatWasNeverLiveHasNoLine() async throws {
        let p = try await pairedPeer("Phone")
        guard case .welcome? = await p.hello() else { return XCTFail("no welcome") }
        p.closeControl()
        _ = await p.waitClosed()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(ends.all.isEmpty, "\(ends.all.map(\.line))")
    }

    // MARK: helpers

    private func pairedPeer(_ name: String) async throws -> ScriptedPeer {
        let code = try await service.beginPairing()
        let p = ScriptedPeer(name: name)
        peers.append(p)
        try p.connect(port: port)
        let result = try await p.pair(code: code)
        guard case .ok = result else { throw PeerError.pairing(result) }
        return p
    }

    private func livePeer(_ name: String) async throws -> ScriptedPeer {
        let p = try await pairedPeer(name)
        try await p.open(port: port)
        _ = await p.next { $0.gameState != nil }
        return p
    }

    private struct NoEnd: Error {}

    /// The first report, within `timeout`.
    private func end(timeout: TimeInterval = 3) async throws -> SessionEndReport {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = ends.all.first { return r }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("no session-end line")
        throw NoEnd()
    }
}
#endif
