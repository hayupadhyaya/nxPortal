#if os(macOS)
import XCTest
import Foundation
import Network
import PortalKit
import PortalTestSupport
import PortalHostCore
@testable import PortalClientCore

/// A media path that never opens ends the session in 2 s; one that opened keeps the 10 s silence limit; a device that
/// reaches the Mac at a second address gets its pictures -> .claude/client.md § session
final class MediaPathTests: XCTestCase {
    private let fakeID = "FAKE000000000000"
    private var dir: URL!
    private var launcher: FakeLauncher!
    private var service: HostService!
    private var port: UInt16 = 0
    private var sessions: [ClientSession] = []
    private var collectors: [Collector] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-p-" + UUID().uuidString)
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

    // MARK: the 2 s rule

    /// Nothing from the Host ever arrives on the media path (the test link drops all of it; control works): the session
    /// ends 2 s after its media started, with `mediaPathSilent`, not after the 10 s silence limit.
    func testAMediaPathThatNeverOpensEndsTheSessionInTwoSeconds() async throws {
        let s = session()
        await s.setIncomingDatagramFilter { _ in false }  // Host -> device: everything dropped, from the start
        let c = collect(s)
        try await s.open(host: try await paired(s))
        let opened = Date()
        let ended = await waitFor(4) { c.finished == 3 }
        let after = Date().timeIntervalSince(opened)
        XCTAssertTrue(ended, "still open after \(after) s")
        XCTAssertLessThanOrEqual(after, 2.5, "ended after \(after) s")
        XCTAssertGreaterThanOrEqual(after, 1.8, "ended after \(after) s: before an answer was 2 s late")
        let end = await s.end
        XCTAssertEqual(end, .mediaPathSilent)
    }

    /// One datagram arrived, then nothing: the media path did open, so only the 10 s silence limit ends the session
    /// (a radio stall must not end it at 2 s).
    func testASessionThatHeardOneDatagramStillLastsTheTenSecondLimit() async throws {
        XCTAssertEqual(ClientSession.defaultSilenceTimeout, 10)
        let s = session()
        let c = collect(s)
        try await s.open(host: try await paired(s))
        let answered = await waitForAsync(2) { await s.stats().rttMs > 0 }
        XCTAssertTrue(answered, "no pong arrived")
        await s.setIncomingDatagramFilter { _ in false }
        let quiet = Date()
        try await Task.sleep(nanoseconds: 9_000_000_000)
        XCTAssertEqual(c.finished, 0, "ended after \(Date().timeIntervalSince(quiet)) s of a 10 s limit")
        let ended = await waitFor(2.5) { c.finished == 3 }
        XCTAssertTrue(ended, "still open \(Date().timeIntervalSince(quiet)) s after the last datagram")
        let end = await s.end
        XCTAssertEqual(end, .silence)
    }

    // MARK: a Mac with several addresses

    /// The device sends its media from another address of this machine to 127.0.0.1: the Host's answers must come
    /// from 127.0.0.1, or the device's connected flow drops every one and no picture arrives.
    func testADeviceThatReachesTheHostAtASecondAddressGetsPictures() async throws {
        guard let other = LocalAddresses.nonLoopbackIPv4() else {
            throw XCTSkip("this machine has no IPv4 address besides loopback: nothing to send from")
        }
        let s = session(mediaFrom: other)
        let c = collect(s)
        try await s.open(host: try await paired(s))
        try await s.launch(titleID: fakeID)
        let pictures = await waitFor(5) { c.frames.count >= 5 }
        let end = await s.end
        XCTAssertTrue(pictures, "frames \(c.frames.count), session end \(String(describing: end))")
    }

    // MARK: helpers

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    private var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    private func session(mediaFrom: String? = nil) -> ClientSession {
        let s = ClientSession(identity: Identity(), name: "Test Client", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 5, mediaFrom: mediaFrom)
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

    private func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func waitForAsync(_ timeout: TimeInterval, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await cond()
    }
}
#endif
