import XCTest
import Foundation
import PortalKit
@testable import PortalClientCore

/// The session's wire-visible send rules, on a session with no link (the send seam records what it would send)
/// -> .claude/client.md § rate, § session
final class SessionSendRulesTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(at: UInt64, d: Datagram)] = []
        func add(_ d: Datagram) { lock.lock(); items.append((uptimeNs(), d)); lock.unlock() }
        func clear() { lock.lock(); items.removeAll(); lock.unlock() }
        var all: [(at: UInt64, d: Datagram)] { lock.lock(); defer { lock.unlock() }; return items }
        var inputs: Int { all.filter { if case .input = $0.d { true } else { false } }.count }
        var rates: [(at: UInt64, bps: UInt32)] {
            all.compactMap { if case let .rate(b) = $0.d { ($0.at, b) } else { nil } }
        }
        /// "rate", "key", "repair" in send order.
        var kinds: [String] {
            all.compactMap {
                switch $0.d {
                case .rate: "rate"
                case .keyRequest: "key"
                case .repair: "repair"
                default: nil
                }
            }
        }
    }

    private func session() async -> (ClientSession, Sent) {
        let s = ClientSession(identity: Identity(), name: "Test Client", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              bitrate: 100_000_000, replyTimeout: 5)
        addTeardownBlock { await s.close() }
        let sent = Sent()
        await s.setSendObserver { sent.add($0) }
        return (s, sent)
    }

    private func piece(_ frame: UInt32, _ index: UInt16, count: UInt16 = 5, key: Bool = false) -> VideoFragment {
        VideoFragment(frame: frame, index: index, count: count, key: key, captureNs: 0, width: 64, height: 64,
                      payload: Data(repeating: 1, count: Wire.maxVideoPayload))
    }

    /// Key frame 1 out, then frames 2 and 3 each missing a fragment and given up, 1 s before `now`; the session has
    /// received 1,000 fragments of a stream that began `streamAgeNs` before `now`.
    private func giveUpTwo(_ s: ClientSession, now: UInt64, streamAgeNs: UInt64) async {
        let t0 = now - 1_000_000_000
        await s.prepareGivenUpFrames(at: t0, streamSince: now - streamAgeNs)
    }

    private func pad(_ buttons: UInt64, motion: MotionSample? = nil) -> InputState {
        InputState(seq: 0, player: 0, buttons: buttons, lx: 0, ly: 0, rx: 0, ry: 0, motion: motion)
    }

    /// A neutral input goes out 5 times and then rests; any new input starts the re-send again -> .claude/client.md § session
    func testNeutralInputStopsRepeating() async throws {
        let (s, sent) = await session()
        await s.send(pad(1))
        sent.clear()
        for _ in 0..<20 { await s.tick() }
        XCTAssertEqual(sent.inputs, 20, "a held input repeats on every tick")
        await s.send(pad(0))
        sent.clear()
        for _ in 0..<20 { await s.tick() }
        XCTAssertEqual(sent.inputs, 4, "the send itself was the first of 5; the ticks add 4, then it rests")
        await s.send(pad(2))
        sent.clear()
        for _ in 0..<5 { await s.tick() }
        XCTAssertEqual(sent.inputs, 5, "a new input did not start the re-send again")
    }

    /// Two frames given up and settled make loss trouble: the first sample cuts, and sends the cut three times.
    func testACutIsSentThreeTimesThirtyMillisecondsApart() async throws {
        let (s, sent) = await session()
        await s.startedMedia()
        sent.clear()
        let now = uptimeNs()
        await giveUpTwo(s, now: now, streamAgeNs: 5_000_000_000)
        await s.rateSample(now)
        let first = await s.rate?.rateBps
        XCTAssertEqual(first, 35_000_000, "a cut of the start's 50 Mbit/s")
        try await Task.sleep(for: .milliseconds(200))
        let rates = sent.rates
        XCTAssertEqual(rates.map(\.bps), [35_000_000, 35_000_000, 35_000_000], "the cut and its two repeats")
        for (a, b) in zip(rates, rates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.at - a.at, 25_000_000, "repeats closer than 30 ms")
            XCTAssertLessThan(b.at - a.at, 120_000_000)
        }
    }

    /// Frames given up in a stream's first second are not trouble for the rate: no cut.
    func testGiveUpsInAStreamsFirstSecondAreNotCounted() async {
        let (s, sent) = await session()
        let now = uptimeNs()
        await giveUpTwo(s, now: now, streamAgeNs: 600_000_000)
        await s.rateSample(now)
        let rate = await s.rate?.rateBps
        XCTAssertEqual(rate, 50_000_000, "the first second's give-ups cut the rate")
        XCTAssertTrue(sent.rates.isEmpty)
    }

    /// After a stall the newest rate goes out before the key request (the refresh is sized by it).
    func testTheRateIsSentBeforeTheKeyRequestAfterAStall() async {
        let (s, sent) = await session()
        await s.markStalledForTest()
        await s.heard(uptimeNs())
        XCTAssertEqual(sent.kinds, ["rate", "key"])
    }

    /// A frame given up with a repair possible: the rate sample (a cut) is sent before the `repair`.
    func testTheRateSampleGoesBeforeTheRepair() async {
        let (s, sent) = await session()
        let now = uptimeNs()
        await giveUpTwo(s, now: now, streamAgeNs: 5_000_000_000)
        await s.refreshForTest(now)
        XCTAssertEqual(sent.kinds, ["rate", "repair"])
    }
}

extension ClientSession {
    /// Key frame 1 out, frames 2 and 3 each short of fragment 2 and given up (all at `t0`, ms apart).
    func prepareGivenUpFrames(at t0: UInt64, streamSince: UInt64) {
        let ms: UInt64 = 1_000_000
        _ = assembler.push(VideoFragment(frame: 1, index: 0, count: 1, key: true, captureNs: 0, width: 64, height: 64,
                                         payload: Data([1])), nowNs: t0)
        for f: UInt32 in [2, 3] {
            for i: UInt16 in [0, 1, 3, 4] {
                _ = assembler.push(VideoFragment(frame: f, index: i, count: 5, key: false, captureNs: 0, width: 64, height: 64,
                                                 payload: Data(repeating: 1, count: Wire.maxVideoPayload)), nowNs: t0 + ms)
            }
        }
        for k in 0..<30 { _ = assembler.tick(nowNs: t0 + UInt64(2 + k * 10) * ms, rttNs: 2 * ms) }
        fragmentsIn = 1000
        videoSinceNs = streamSince
    }
    func markStalledForTest() { stalled = true; lastHeardNs = 1 }
    /// The assembler asked for a refresh: the session handles it as it does a tick's events.
    func refreshForTest(_ now: UInt64) {
        assembler.acceptsRepair = true
        handle([.refresh(lastGood: nil)], now)
    }
}
