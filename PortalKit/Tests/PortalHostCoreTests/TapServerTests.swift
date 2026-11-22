#if os(macOS)
import XCTest
import Foundation
import PortalKit
import PortalTestSupport
@testable import PortalHostCore

/// Collects a server's events; waits poll the collected list (the stream has one consumer).
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()  // guards items, done
    private var items: [TapEvent] = []
    private var task: Task<Void, Never>?

    private var done = false

    init(_ stream: AsyncStream<TapEvent>) {
        task = Task { [weak self] in
            for await e in stream { self?.append(e) }
            self?.markDone()
        }
    }
    deinit { task?.cancel() }

    private func append(_ e: TapEvent) { lock.lock(); items.append(e); lock.unlock() }
    var all: [TapEvent] { lock.lock(); defer { lock.unlock() }; return items }
    private func markDone() { lock.lock(); done = true; lock.unlock() }
    /// The stream has finished.
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done }

    @discardableResult
    func wait(timeout: TimeInterval = 10, until cond: ([TapEvent]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(all) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond(all)
    }
}

extension TapEvent {
    var isHello: Bool { if case .hello = self { return true }; return false }
    var isClosed: Bool { if case .closed = self { return true }; return false }
    var isVideo: Bool { if case .video = self { return true }; return false }
    var isAudio: Bool { if case .audio = self { return true }; return false }
    var isRefused: Bool { if case .refused = self { return true }; return false }
    var isKeyVideo: Bool { if case let .video(_, _, _, _, mark, _, _) = self { return mark == .key }; return false }
}

/// A fake game's `run()` on a task, with a done flag.
final class RunningFake: @unchecked Sendable {
    let game: FakeGame
    private let lock = NSLock()  // guards finished, error
    private var finished = false
    private var error: Error?
    private var task: Task<Void, Never>?

    init(_ game: FakeGame) {
        self.game = game
        task = Task { [self] in
            do { try await game.run(); finish(nil) } catch { finish(error) }
        }
    }
    private func finish(_ e: Error?) { lock.lock(); error = e; finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }
    func waitFinished(timeout: TimeInterval = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end && !isFinished { try? await Task.sleep(nanoseconds: 5_000_000) }
        return isFinished
    }
}

final class TapServerTests: XCTestCase {
    private var path = ""
    private var server: TapServer!
    private var events: EventCollector!
    private var fakes: [RunningFake] = []

    override func setUp() async throws {
        continueAfterFailure = false
        path = "/tmp/nxp-t-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)) + ".sock"
        server = TapServer(socketPath: path)
        events = EventCollector(server.events)
        try await server.start()
    }

    override func tearDown() async throws {
        for f in fakes { f.game.stop() }
        for f in fakes { _ = await f.waitFinished() }
        await server.stop()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func startFake(version: UInt16 = ProtocolVersion.tap) -> RunningFake {
        let f = RunningFake(FakeGame(socketPath: path, version: version))
        fakes.append(f)
        return f
    }

    private func helloCount(_ e: [TapEvent]) -> Int { e.filter(\.isHello).count }
    private func videoCount(_ e: [TapEvent]) -> Int { e.filter(\.isVideo).count }

    func testHelloAndFrames() async throws {
        _ = startFake()
        let gotHello = await events.wait { $0.contains(where: \.isHello) }
        XCTAssertTrue(gotHello)
        guard case let .hello(id, name) = events.all.first(where: \.isHello) else { return XCTFail("no hello") }
        XCTAssertEqual(id, "FAKE000000000000")
        XCTAssertEqual(name, "Fake Game")

        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        let ok = await events.wait(timeout: 2) { e in
            e.filter(\.isVideo).count >= 60 && e.filter(\.isAudio).count >= 150
        }
        XCTAssertTrue(ok, "video \(videoCount(events.all)), audio \(events.all.filter(\.isAudio).count)")
        let all = events.all
        guard case let .video(_, _, w, h, mark, _, data)? = all.first(where: \.isVideo) else { return XCTFail("no video") }
        XCTAssertEqual(mark, .key)
        XCTAssertEqual(w, 1280)
        XCTAssertEqual(h, 720)
        XCTAssertNotNil(HEVC.parameterSets(data), "key frame carries VPS, SPS, PPS")
        for case let .audio(_, pcm) in all { XCTAssertEqual(pcm.count, 960) }
        XCTAssertTrue(all.first?.isHello == true)
    }

    func testInputReachesGame() async throws {
        let fake = startFake()
        await events.wait { $0.contains(where: \.isHello) }
        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        await events.wait { self.videoCount($0) >= 3 }
        // Only the first frame is a key frame unless one is requested.
        let before = videoCount(events.all)
        let pad = TapMessage.pad(player: 0, buttons: 1, lx: 0, ly: 0, rx: 0, ry: 0)
        server.send(pad)
        server.send(.keyframe)
        let arrived = await events.wait { _ in fake.game.received.count >= 3 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(Array(fake.game.received.suffix(2)), [pad, .keyframe])
        let keyed = await events.wait { e in e.filter(\.isVideo).dropFirst(1).contains(where: \.isKeyVideo) }
        XCTAssertTrue(keyed)
        XCTAssertGreaterThan(videoCount(events.all), before)
    }

    func testConfigCapsSize() async throws {
        _ = startFake()
        await events.wait { $0.contains(where: \.isHello) }
        server.send(.config(maxWidth: 640, maxHeight: 360, maxFps: 30, bitrate: 5_000_000))
        await events.wait { self.videoCount($0) >= 5 }
        let start = videoCount(events.all)
        let t0 = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let rate = Double(videoCount(events.all) - start) / Date().timeIntervalSince(t0)
        XCTAssertTrue((25...35).contains(rate), "rate \(rate)")
        for case let .video(_, _, w, h, _, _, _) in events.all {
            XCTAssertEqual(w, 640)
            XCTAssertEqual(h, 360)
        }
    }

    func testFakeGameSoundContinuesWhilePaused() async throws {
        _ = startFake()
        await events.wait { $0.contains(where: \.isHello) }
        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        await events.wait { self.videoCount($0) >= 3 }
        server.send(.pause(true))
        try await Task.sleep(nanoseconds: 100_000_000)  // frames already in flight
        let video = videoCount(events.all)
        let audio = events.all.filter(\.isAudio).count
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(videoCount(events.all), video)
        let blocks = events.all.filter(\.isAudio).count - audio
        XCTAssertGreaterThanOrEqual(blocks, 50, "audio blocks \(blocks)")
    }

    func testFakeGameSameSizeConfigNoKeyframe() async throws {
        _ = startFake()
        await events.wait { $0.contains(where: \.isHello) }
        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        await events.wait { self.videoCount($0) >= 3 }
        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        let same = await events.wait { self.videoCount($0) >= 20 }
        XCTAssertTrue(same)
        XCTAssertEqual(events.all.filter(\.isKeyVideo).count, 1, "only the first frame is a key frame")

        let before = videoCount(events.all)
        server.send(.config(maxWidth: 640, maxHeight: 360, maxFps: 60, bitrate: 5_000_000))
        let resized = await events.wait { e in
            e.dropFirst().contains { if case let .video(_, _, w, h, mark, _, _) = $0 { return mark == .key && w == 640 && h == 360 }; return false }
        }
        XCTAssertTrue(resized)
        XCTAssertGreaterThan(videoCount(events.all), before)
    }

    /// A tap-1 game (no token in `video`) is refused with the version message.
    func testVersionMismatchRefused() async throws {
        let fake = startFake(version: 1)
        let closed = await events.wait { $0.contains(where: \.isClosed) }
        XCTAssertTrue(closed)
        let all = events.all
        XCTAssertFalse(all.contains(where: \.isHello))
        guard case let .refused(text)? = all.first(where: \.isRefused) else { return XCTFail("no refusal") }
        XCTAssertEqual(text, "tap protocol 1, Host speaks 2")
        XCTAssertTrue(all.last?.isClosed == true)
        XCTAssertEqual(all.filter(\.isClosed).count, 1)
        let ended = await fake.waitFinished()
        XCTAssertTrue(ended)
    }

    func testQuitEndsGame() async throws {
        let fake = startFake()
        await events.wait { $0.contains(where: \.isHello) }
        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        await events.wait { self.videoCount($0) >= 2 }
        server.send(.quit)
        let ended = await fake.waitFinished()
        XCTAssertTrue(ended)
        XCTAssertNil(fake.failure)
        let closed = await events.wait { $0.contains(where: \.isClosed) }
        XCTAssertTrue(closed)
    }

    func testOversizedMessageClosed() async throws {
        let raw = try rawConnect(path)
        defer { close(raw) }
        var len = UInt32.max
        XCTAssertEqual(write(raw, &len, 4), 4)
        let closed = await events.wait { $0.contains(where: \.isClosed) }
        XCTAssertTrue(closed)
        XCTAssertFalse(events.all.contains(where: \.isHello))
        _ = startFake()
        let hello = await events.wait { $0.contains(where: \.isHello) }
        XCTAssertTrue(hello, "server accepts the next game")
    }

    func testSecondGameWaits() async throws {
        let first = startFake()
        await events.wait { $0.contains(where: \.isHello) }
        let second = startFake()
        // A negative cannot be awaited: give the server a real chance to (wrongly) accept.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(helloCount(events.all), 1)
        first.game.stop()
        let ok = await events.wait { self.helloCount($0) == 2 }
        XCTAssertTrue(ok)
        XCTAssertFalse(second.isFinished)
        XCTAssertGreaterThanOrEqual(events.all.filter(\.isClosed).count, 1)
    }

    func testSilentConnectionDropped() async throws {
        let raw = try rawConnect(path)
        defer { close(raw) }
        let closed = await events.wait(timeout: 6) { $0.contains(where: \.isClosed) }
        XCTAssertTrue(closed, "a connection without hello is dropped")
        _ = startFake()
        let hello = await events.wait { $0.contains(where: \.isHello) }
        XCTAssertTrue(hello, "server accepts the next game")
    }

    func testStopWhileStreaming() async throws {
        let fake = startFake()
        await events.wait { $0.contains(where: \.isHello) }
        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        await events.wait { self.videoCount($0) >= 2 }
        await server.stop()
        let ended = await fake.waitFinished()
        XCTAssertTrue(ended)
        let finished = await events.wait { _ in self.events.isFinished }
        XCTAssertTrue(finished, "events stream finishes")
        XCTAssertEqual(events.all.filter(\.isClosed).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    private func writeAll(_ fd: Int32, _ messages: [Data]) {
        for m in messages { _ = m.withUnsafeBytes { write(fd, $0.baseAddress!, m.count) } }
    }

    /// A message of a type the Host does not know is skipped by its length and reported; the connection goes on and
    /// the next message is delivered.
    func testAnUnknownTapMessageIsSkippedAndTheNextOneDelivered() async throws {
        let raw = try rawConnect(path)
        defer { close(raw) }
        writeAll(raw, [TapMessage.hello(version: ProtocolVersion.tap, titleID: "FAKE000000000000", name: "Raw").encoded(),
                       Data([3, 0, 0, 0, 0x7E, 1, 2]),
                       TapMessage.prepare(phase: 1, done: 0, total: 9).encoded()])
        let got = await events.wait { $0.contains { if case .prepare = $0 { true } else { false } } }
        XCTAssertTrue(got, "\(events.all)")
        let all = events.all
        XCTAssertTrue(all.contains { if case .skipped(0x7E) = $0 { true } else { false } }, "\(all)")
        XCTAssertTrue(all.contains { if case .prepare(1, 0, 9) = $0 { true } else { false } })
        XCTAssertFalse(all.contains(where: \.isClosed))
    }

    /// `prepare` before `hello` is a protocol error like any other message before it.
    func testPrepareBeforeHelloIsRefused() async throws {
        let raw = try rawConnect(path)
        defer { close(raw) }
        writeAll(raw, [TapMessage.prepare(phase: 1, done: 0, total: 9).encoded()])
        let closed = await events.wait { $0.contains(where: \.isClosed) }
        XCTAssertTrue(closed)
        guard case let .refused(text)? = events.all.first(where: \.isRefused) else { return XCTFail("no refusal") }
        XCTAssertEqual(text, "expected hello")
    }

    /// A known message of the wrong size stays fatal (here a `video` flags byte of 3: key and repair).
    func testAMalformedKnownMessageEndsTheConnection() async throws {
        let raw = try rawConnect(path)
        defer { close(raw) }
        var bad = TapMessage.video(frame: 0, captureNs: 0, width: 2, height: 2, mark: .key, token: -1, data: Data([1])).encoded()
        bad[21] = 3
        writeAll(raw, [TapMessage.hello(version: ProtocolVersion.tap, titleID: "FAKE000000000000", name: "Raw").encoded(), bad])
        let closed = await events.wait { $0.contains(where: \.isClosed) }
        XCTAssertTrue(closed)
        XCTAssertFalse(events.all.contains(where: \.isVideo))
    }

    func testStartAfterStopThrows() async throws {
        await server.stop()
        do {
            try await server.start()
            XCTFail("restarted")
        } catch {
            XCTAssertEqual(error as? TapServerError, .stopped)
        }
    }

    private func rawConnect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw XCTSkip("connect failed \(errno)") }
        return fd
    }
}

/// The padded mode of the fake game -> .claude/portalkit.md § test-network
final class PaddedFakeGameTests: XCTestCase {
    func testPaddedFramesFollowTheConfiguredBitrateAndAConfigChangesItFromTheNextFrame() async throws {
        let path = "/tmp/nxp-p-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)) + ".sock"
        let server = TapServer(socketPath: path)
        let events = EventCollector(server.events)
        try await server.start()
        let fake = RunningFake(FakeGame(socketPath: path, paddedToBitrate: true))
        defer { try? FileManager.default.removeItem(atPath: path) }
        await events.wait { $0.contains(where: \.isHello) }

        func sizes(_ e: [TapEvent]) -> [(key: Bool, bytes: Int)] {
            e.compactMap { if case let .video(_, _, _, _, mark, _, data) = $0 { (mark == .key, data.count) } else { nil } }
        }
        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 20_000_000))
        await events.wait { sizes($0).count >= 30 }
        let first = sizes(events.all)
        let perFrame = 20_000_000 / 8 / 60  // 41 666
        let deltas = first.filter { !$0.key }.map(\.bytes)
        XCTAssertFalse(deltas.isEmpty)
        for b in deltas { XCTAssertTrue((perFrame - 200...perFrame + 200).contains(b), "delta frame \(b) bytes") }
        let key = try XCTUnwrap(first.first { $0.key }, "no key frame")
        XCTAssertTrue((4 * perFrame - 200...4 * perFrame + 200).contains(key.bytes), "key frame \(key.bytes) bytes")

        server.send(.config(maxWidth: 1280, maxHeight: 720, maxFps: 60, bitrate: 5_000_000))
        let before = sizes(events.all).count
        await events.wait { sizes($0).count >= before + 30 }
        let small = 5_000_000 / 8 / 60
        let later = sizes(events.all).dropFirst(before + 10).filter { !$0.key }.map(\.bytes)  // a few frames were in flight
        XCTAssertFalse(later.isEmpty)
        for b in later { XCTAssertTrue((small - 200...small + 200).contains(b), "after the change: \(b) bytes") }

        fake.game.stop()
        _ = await fake.waitFinished()
        await server.stop()
    }
}
#endif
