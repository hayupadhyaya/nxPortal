#if os(macOS)
import XCTest
import Foundation
import Network
import PortalKit
import PortalTestSupport
@testable import PortalHostCore

/// What a service's `status` stream yielded; the stream has one consumer.
final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()  // guards items, done
    private var items: [HostStatus] = []
    private var done = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<HostStatus>) {
        task = Task { [weak self] in
            for await s in stream { self?.lock.withLock { self?.items.append(s) } }
            self?.lock.withLock { self?.done = true }
        }
    }
    deinit { task?.cancel() }

    var all: [HostStatus] { lock.withLock { items } }
    var isFinished: Bool { lock.withLock { done } }
    var failure: String? { all.compactMap { if case let .failed(t) = $0 { t } else { nil } }.first }

    static func poll(timeout: TimeInterval = 5, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    func wait(timeout: TimeInterval = 5, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }
}

/// Holds a test hook until `open()`; `waitEntered()` says whether something is held within 2 s. Open it in a `defer`:
/// a failed assertion must not leave a start suspended.
final class Gate: @unchecked Sendable {
    private let release: AsyncStream<Void>, releaseOut: AsyncStream<Void>.Continuation
    private let lock = NSLock()  // guards didEnter
    private var didEnter = false
    init() { (release, releaseOut) = AsyncStream.makeStream(of: Void.self) }
    func hold() async {
        lock.withLock { didEnter = true }
        for await _ in release { return }
    }
    func waitEntered(timeout: TimeInterval = 2) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if lock.withLock({ didEnter }) { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return lock.withLock { didEnter }
    }
    func open() { releaseOut.yield(()) }
}

/// A game whose `terminate()` takes 0.4 s.
final class SlowLauncher: GameLaunching, @unchecked Sendable {
    private let lock = NSLock()  // guards both flags
    private var _launched = false, _terminated = false
    var launched: Bool { lock.withLock { _launched } }
    var terminated: Bool { lock.withLock { _terminated } }
    fileprivate func markTerminated() { lock.withLock { _terminated = true } }

    func launch(titleID: String, socketPath: String) async throws -> any RunningGame {
        lock.withLock { _launched = true }
        return SlowGame(owner: self)
    }
}

private struct SlowGame: RunningGame {
    let owner: SlowLauncher
    func terminate() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        owner.markTerminated()
    }
    func waitForExit() async -> Int32 {
        while !owner.terminated { try? await Task.sleep(nanoseconds: 10_000_000) }
        return 15
    }
}

/// Start failures, listener failures -> .claude/host.md § service
final class HostServiceLifecycleTests: XCTestCase {
    private var dir: URL!
    private var held: [Int32] = []

    override func setUp() async throws {
        continueAfterFailure = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-lc-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        held.forEach { close($0) }
        try? FileManager.default.removeItem(at: dir)
    }

    private let fakeID = "FAKE000000000000"

    private func makeService(port: UInt16 = 0, tapPath: String, launcher: any GameLaunching = FakeLauncher()) throws -> HostService {
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        var config = HostConfig(name: "Test Host", storeURL: dir.appendingPathComponent("host.json"), libraryRoots: [],
                                launcher: launcher, power: RecordingPower(), advertise: false, port: port, extraGames: [fake])
        config.tapSocketPath = tapPath
        return try HostService(config: config)
    }

    private func tapPath() -> String { "/tmp/nxp-lc-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)) + ".sock" }

    /// A TCP port something else is listening on (the descriptor stays open until tearDown).
    private func occupiedPort() throws -> UInt16 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        held.append(fd)
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
        return UInt16(bigEndian: addr.sin6_port)
    }

    /// A TCP port nothing listens on at the moment.
    private func freePort() throws -> UInt16 {
        let port = try occupiedPort()
        close(held.removeLast())
        return port
    }

    /// Both UDP families can bind the port: nothing of the service holds it.
    private func udpPortIsFree(_ port: UInt16) -> Bool {
        var free = true
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_DGRAM, 0)
            defer { close(fd) }
            let rc: Int32
            if family == AF_INET {
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var a = sockaddr_in6()
                a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port.bigEndian
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if rc != 0 { free = false }
        }
        return free
    }

    /// `start()` on a TCP port that is taken throws and has released everything: both UDP sockets, the tap socket file,
    /// the tasks; `status` has finished with `.failed`. A new object on a free port starts.
    func testStartFailureReleasesEverything() async throws {
        let tap = tapPath()
        defer { try? FileManager.default.removeItem(atPath: tap) }
        let taken = try occupiedPort()
        let failing = try makeService(port: taken, tapPath: tap)
        let status = StatusCollector(failing.status)
        do {
            _ = try await failing.start()
            return XCTFail("start() on a taken port returned")
        } catch {}
        let udp = await failing.mediaPort
        XCTAssertNotEqual(udp, 0, "the media sockets were never opened: the test proves nothing")
        XCTAssertTrue(udpPortIsFree(udp), "a UDP socket of the failed start is still open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tap), "the tap socket file is still there")
        let finished = await status.wait { status.isFinished }
        XCTAssertTrue(finished, "status did not finish")
        XCTAssertNotNil(status.failure, "no .failed in \(status.all)")
        await failing.stop()  // after a failed start: returns, changes nothing

        let next = try makeService(tapPath: tap)
        addTeardownBlock { await next.stop() }
        _ = try await next.start()
        await next.stop()
    }

    /// A listener that fails after it was ready: `status` yields `.failed` (text without an address), and `stop()` returns.
    func testListenerFailureIsReported() async throws {
        let tap = tapPath()
        defer { try? FileManager.default.removeItem(atPath: tap) }
        let service = try makeService(tapPath: tap)
        let status = StatusCollector(service.status)
        _ = try await service.start()
        await service.control.failForTest(NWError.posix(.ENETDOWN))
        let reported = await status.wait { status.failure != nil }
        XCTAssertTrue(reported, "no .failed in \(status.all)")
        let text = status.failure ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertNil(text.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression), "an address in: \(text)")
        await service.stop()
        let finished = await status.wait { status.isFinished }
        XCTAssertTrue(finished)
    }

    /// Two services in one process, on the default socket folder: each launches its game, both reach `running`.
    func testTwoServicesInOneProcess() async throws {
        let fakeID = "FAKE000000000000"
        let fake = GameApp(titleID: fakeID, name: "Fake Game", url: URL(fileURLWithPath: "/nonexistent/Fake.app"), streamable: true)
        var services: [HostService] = [], peers: [ScriptedPeer] = [], launchers: [FakeLauncher] = []
        defer { peers.forEach { $0.close() } }
        for i in 0..<2 {
            let launcher = FakeLauncher()
            launchers.append(launcher)
            let config = HostConfig(name: "Host \(i)", storeURL: dir.appendingPathComponent("host\(i).json"), libraryRoots: [],
                                    launcher: launcher, power: RecordingPower(), advertise: false, port: 0, extraGames: [fake])
            let service = try HostService(config: config)
            addTeardownBlock { await service.stop() }
            services.append(service)
            let port = try await service.start()
            let peer = ScriptedPeer(identity: Identity(), name: "Device \(i)")
            peers.append(peer)
            try peer.connect(port: port)
            let result = try await peer.pair(code: try await service.beginPairing())
            guard case .ok = result else { return XCTFail("pairing \(i): \(result)") }
            try await peer.open(port: port)
        }
        for (i, peer) in peers.enumerated() {
            peer.send(.launch(titleID: fakeID))
            let running = await peer.next { $0.gameState?.run == .running }
            XCTAssertNotNil(running, "service \(i) never reached running")
        }
        for l in launchers { l.game?.stop() }
        for s in services { await s.stop() }
    }

    /// `stop()` while `start()` waits (held after the tap opened): `start()` throws `CancellationError`, and nothing is left:
    /// no media socket was opened, the tap socket file is gone, `status` finished, the TCP port is free for a new service.
    func testStopDuringStartLeavesNothing() async throws {
        let tap = tapPath()
        defer { try? FileManager.default.removeItem(atPath: tap) }
        let port = try freePort()
        let service = try makeService(port: port, tapPath: tap)
        addTeardownBlock { await service.stop() }
        let status = StatusCollector(service.status)
        let gate = Gate()
        defer { gate.open() }
        await service.holdStart { await gate.hold() }
        let starting = Task { try await service.start() }
        let entered = await gate.waitEntered()
        XCTAssertTrue(entered, "start() never reached the hold")
        await service.stop()
        gate.open()
        do {
            _ = try await starting.value
            XCTFail("start() returned after stop()")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let udp = await service.mediaPort
        XCTAssertEqual(udp, 0, "the media sockets were opened after stop()")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tap), "the tap socket file is still there")
        let finished = await status.wait { status.isFinished }
        XCTAssertTrue(finished, "status did not finish")
        let next = try makeService(port: port, tapPath: tap)
        addTeardownBlock { await next.stop() }
        let bound = try await next.start()
        XCTAssertEqual(bound, port, "the TCP port was not free")
        await next.stop()
    }

    /// `stop()` before the control listener is stored (it starts off the actor): the listener is not left bound. A new
    /// service binds the same TCP port. (The listener's own state is what is asserted through the port; browsing for the
    /// advertised service is not done: this service does not advertise, and the bound port is the same listener.)
    func testStopBeforeTheListenerIsStoredClosesIt() async throws {
        let tap = tapPath()
        defer { try? FileManager.default.removeItem(atPath: tap) }
        let port = try freePort()
        let service = try makeService(port: port, tapPath: tap)
        addTeardownBlock { await service.stop() }
        let gate = Gate()
        defer { gate.open() }
        await service.control.holdBeforeStore { await gate.hold() }
        let starting = Task { try await service.start() }
        let entered = await gate.waitEntered()
        XCTAssertTrue(entered, "the listener's start never reached the hold")
        await service.stop()
        gate.open()
        do {
            _ = try await starting.value
            XCTFail("start() returned after stop()")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let next = try makeService(port: port, tapPath: tap)
        addTeardownBlock { await next.stop() }
        let bound: UInt16
        do { bound = try await next.start() } catch { return XCTFail("the TCP port was left bound: \(error)") }
        XCTAssertEqual(bound, port, "the TCP port was left bound")
        await next.stop()
    }

    /// `stop()` while a launch waits for the library scan: the launcher is never called.
    func testLaunchAfterStopStartsNothing() async throws {
        let tap = tapPath()
        defer { try? FileManager.default.removeItem(atPath: tap) }
        let launcher = FakeLauncher()
        let service = try makeService(tapPath: tap, launcher: launcher)
        addTeardownBlock { await service.stop() }
        let port = try await service.start()
        let peer = ScriptedPeer(identity: Identity(), name: "Device")
        defer { peer.close() }
        try peer.connect(port: port)
        let result = try await peer.pair(code: try await service.beginPairing())
        guard case .ok = result else { return XCTFail("pairing: \(result)") }
        try await peer.open(port: port)
        let gate = Gate()
        defer { gate.open() }
        await service.holdScan { await gate.hold() }
        peer.send(.launch(titleID: fakeID))
        let entered = await gate.waitEntered()
        XCTAssertTrue(entered, "the launch never reached the scan")
        await service.stop()
        gate.open()
        try await Task.sleep(nanoseconds: 500_000_000)  // a negative: give the launch a real chance to (wrongly) go on
        XCTAssertNil(launcher.game, "a game was launched after stop()")
        launcher.game?.stop()
    }

    /// Two `stop()` calls at once: each returns only when the teardown (the game's `terminate()`) has finished.
    func testStopTwiceWaitsForTheTeardown() async throws {
        let tap = tapPath()
        defer { try? FileManager.default.removeItem(atPath: tap) }
        let launcher = SlowLauncher()
        let service = try makeService(tapPath: tap, launcher: launcher)
        addTeardownBlock { await service.stop() }
        let port = try await service.start()
        let peer = ScriptedPeer(identity: Identity(), name: "Device")
        defer { peer.close() }
        try peer.connect(port: port)
        let result = try await peer.pair(code: try await service.beginPairing())
        guard case .ok = result else { return XCTFail("pairing: \(result)") }
        try await peer.open(port: port)
        peer.send(.launch(titleID: fakeID))
        let launched = await StatusCollector.poll { launcher.launched }
        XCTAssertTrue(launched, "the game was not launched")
        try await Task.sleep(nanoseconds: 100_000_000)  // the service keeps the handle
        let after = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask { await service.stop(); return launcher.terminated } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        XCTAssertEqual(after, [true, true], "a stop() returned before the game was terminated")
    }
}
#endif
