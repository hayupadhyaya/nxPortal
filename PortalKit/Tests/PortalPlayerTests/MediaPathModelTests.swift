#if os(macOS)
import XCTest
import Network
import PortalKit
import PortalHostCore
@testable import PortalTestSupport
@testable import PortalClientCore
@testable import PortalPlayer

/// A Mac that answers on its control connection while its video never reaches the device: the app retries twice, then
/// says so in plain words instead of "Reconnecting…" for ever -> .claude/client.md § model
@MainActor
final class MediaPathModelTests: XCTestCase {
    private let hostName = "Test Host"
    private var dir: URL!
    private var service: HostService!
    private var port: UInt16 = 0
    /// A UDP port that is bound and never read: `welcome` names it, so no datagram reaches the Host and none comes back.
    private var deadSocket: Int32 = -1
    private var models: [ClientModel] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-mp-" + UUID().uuidString)
        deadSocket = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(deadSocket, $0, len) == 0 && getsockname(deadSocket, $0, &len) == 0 }
        }
        XCTAssertTrue(bound)
        var config = HostConfig(name: hostName, storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
                                launcher: FakeLauncher(), power: NoPower(), advertise: false, port: 0)
        config.advertisedMediaPort = UInt16(bigEndian: addr.sin_port)
        service = try HostService(config: config)
        port = try await service.start()
    }

    override func tearDown() async throws {
        for m in models { await m.disconnect() }
        models = []
        await service.stop()
        close(deadSocket)
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheThirdSessionInARowWithoutVideoShowsAPlainMessage() async throws {
        let found = FoundHost(name: hostName, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let m = ClientModel(store: ClientStore(secrets: MemorySecrets()), browser: StubBrowser([found]), deviceName: "Device 1",
                            kind: .tablet, sound: false, retryInterval: 0.1)
        m.start()
        models.append(m)
        await m.choose(found)
        await m.pair(code: try await service.beginPairing())
        let library = await waitFor(3) { m.screen == .library }
        XCTAssertTrue(library, "screen \(m.screen), message \(m.message ?? "-")")

        // First and second: the session ends after 2 s and the usual retry runs.
        let first = await waitFor(3) { m.reconnecting }
        XCTAssertTrue(first, "the first session did not end")
        XCTAssertEqual(m.message, Messages.connectionLost)
        // Third: the retry loop stops with the plain message.
        let blocked = await waitFor(7) { m.message == Messages.mediaPathBlocked }
        XCTAssertTrue(blocked, "screen \(m.screen), reconnecting \(m.reconnecting), message \(m.message ?? "-")")
        XCTAssertFalse(m.reconnecting)
        XCTAssertEqual(m.screen, .library)
        try await Task.sleep(nanoseconds: 1_000_000_000)  // a negative: no fourth attempt
        XCTAssertFalse(m.reconnecting)
        XCTAssertEqual(m.message, Messages.mediaPathBlocked)
        XCTAssertNil(m.session)
        XCTAssertEqual(Messages.mediaPathBlocked,
                       "The Mac answers, but its video cannot reach this device. Check that both are on the same network.")
    }

    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    private func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }
}
#endif
