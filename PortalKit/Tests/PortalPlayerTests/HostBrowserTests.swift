#if os(macOS)
import XCTest
import Network
import PortalKit
import PortalHostCore
import PortalTestSupport
@testable import PortalPlayer

/// The newest list a browser yielded.
final class FoundBox: @unchecked Sendable {
    private let lock = NSLock()  // guards list
    private var list: [FoundHost] = []
    var value: [FoundHost] { get { lock.withLock { list } } set { lock.withLock { list = newValue } } }
}

final class HostBrowserTests: XCTestCase {
    private struct NoPower: PowerHolding { func set(_ awake: Bool) {} }

    private func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    /// The descriptor that delivers TXT records: without it a found Mac has no `id` and a renamed Mac is not recognised.
    func testTheBrowseTypeDeliversTheTXTRecord() {
        let want = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_nxportal._tcp", domain: nil)
        let plain = NWBrowser.Descriptor.bonjour(type: "_nxportal._tcp", domain: nil)
        XCTAssertEqual(String(describing: HostBrowser.descriptor), String(describing: want))
        XCTAssertNotEqual(String(describing: want), String(describing: plain))
    }

    func testFindsAdvertisedHost() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-b-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "nxPortal Test " + UUID().uuidString.prefix(8)
        let service = try HostService(config: HostConfig(
            name: name, storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
            launcher: FakeLauncher(), power: NoPower(), advertise: true, port: 0))
        _ = try await service.start()

        let browser = HostBrowser()
        let box = FoundBox()
        let hosts = browser.hosts
        let reader = Task { for await list in hosts { box.value = list } }
        defer { reader.cancel(); browser.stop() }
        func seen() -> FoundHost? { box.value.first { $0.name == name } }

        browser.start()
        let found = await waitFor(5) { seen() != nil }
        XCTAssertTrue(found, "not found: \(box.value.map(\.name))")
        if case let .service(serviceName, type, _, _)? = seen()?.endpoint {
            XCTAssertEqual(serviceName, name)
            XCTAssertEqual(type, "_nxportal._tcp")
        } else {
            XCTFail("endpoint is not a service: \(String(describing: seen()?.endpoint))")
        }
        XCTAssertEqual(seen()?.id, service.discoveryID, "the Host's id did not arrive with the browse result")
        XCTAssertEqual(box.value, box.value.sorted { $0.name < $1.name })

        browser.stop()
        let cleared = await waitFor(1) { box.value.isEmpty }
        XCTAssertTrue(cleared, "stop() left \(box.value.map(\.name))")
        browser.start()
        let again = await waitFor(5) { seen() != nil }
        XCTAssertTrue(again, "not found after stop() then start()")
        // restart(): a new browser reports the Mac again.
        box.value = []
        browser.restart()
        let restarted = await waitFor(5) { seen() != nil }
        XCTAssertTrue(restarted, "not found after restart()")

        await service.stop()
        let removed = await waitFor(5) { seen() == nil }
        XCTAssertTrue(removed, "still listed after the Host stopped")
    }

    // MARK: advertised id

    private func ad(_ name: String, _ id: String?) -> HostBrowser.Advertised {
        .init(name: name, endpoint: .hostPort(host: "127.0.0.1", port: 1), id: id)
    }

    func testOnlyAWellFormedIDCounts() {
        let valid = "0123456789abcdef"
        XCTAssertEqual(HostBrowser.validID(valid), valid)
        XCTAssertNil(HostBrowser.validID("0123456789ABCDEF"), "uppercase")
        XCTAssertNil(HostBrowser.validID(String(valid.dropLast())), "15 characters")
        XCTAssertNil(HostBrowser.validID(valid + "0"), "17 characters")
        XCTAssertNil(HostBrowser.validID("0123456789abcdeg"), "not hex")
        XCTAssertNil(HostBrowser.validID(""), "empty")
        XCTAssertNil(HostBrowser.validID(nil))
        XCTAssertNil(HostBrowser.validID(String(repeating: "a", count: 10_000)), "10,000 characters")
    }

    func testListTakesOnlyValidIDs() {
        let list = HostBrowser.list([ad("A", "0123456789abcdef"), ad("B", "NOT-AN-ID"), ad("C", nil)])
        XCTAssertEqual(list.map(\.id), ["0123456789abcdef", nil, nil])
    }

    /// One Mac per `id`: the first name in sort order is listed, whatever order the results came in.
    func testOneMacPerAdvertisedID() {
        let id = "0123456789abcdef"
        for entries in [[ad("Zed", id), ad("Alpha", id), ad("Other", "fedcba9876543210")],
                        [ad("Other", "fedcba9876543210"), ad("Alpha", id), ad("Zed", id)]] {
            XCTAssertEqual(HostBrowser.list(entries).map(\.name), ["Alpha", "Other"])
        }
        XCTAssertEqual(HostBrowser.list([ad("X", nil), ad("Y", nil)]).map(\.name), ["X", "Y"], "Macs with no id are all listed")
    }

    /// An entry dropped for a doubled `id` reserves no name: another Mac with that name is still listed.
    func testADroppedEntryDoesNotHideASameNamedMac() {
        let x = "0123456789abcdef", y = "fedcba9876543210"
        let list = HostBrowser.list([ad("A", x), ad("B", x), ad("B", y)])
        XCTAssertEqual(list.map(\.name), ["A", "B"])
        XCTAssertEqual(list.map(\.id), [x, y])
    }
}
#endif
