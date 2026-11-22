import Foundation
import XCTest
@testable import PortalClientCore
import PortalKit

/// The session's repair timer wakes for the assembler's earliest deadline -> .claude/client.md § session
final class RepairTimerTests: XCTestCase {
    private func fragment(_ i: UInt16) -> VideoFragment {
        VideoFragment(frame: 1, index: i, count: 40, key: true, captureNs: 0, width: 64, height: 64, payload: Data([1]))
    }

    /// Polls until `asked` passes `count`; the time it did, or nil after 30 ms.
    private func whenAsked(over count: Int, _ s: ClientSession) async -> UInt64? {
        let end = uptimeNs() + 30_000_000
        while uptimeNs() < end {
            if await s.stats().fragmentsAsked > count { return uptimeNs() }
            try? await Task.sleep(for: .microseconds(100))
        }
        return nil
    }

    /// A hole seen after its frame's first `nack` is asked for after the settle, not at the frame's next retry round
    /// (8 ms after the first ask).
    func testAHoleSeenAfterTheFirstNackIsAskedForAtOnce() async throws {
        let s = ClientSession(identity: Identity(), name: "Test Client", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 5)
        addTeardownBlock { await s.close() }
        for i: UInt16 in [0, 1, 3] { await s.video(fragment(i), uptimeNs()) }  // 2 missing
        let first = await whenAsked(over: 0, s)
        let firstAsk = try XCTUnwrap(first, "the first hole is asked for")
        for i: UInt16 in 4...29 { await s.video(fragment(i), uptimeNs()) }
        await s.video(fragment(31), uptimeNs())  // 30 missing, seen now
        let seen = uptimeNs()
        for i: UInt16 in 32...39 { await s.video(fragment(i), uptimeNs()) }
        let second = await whenAsked(over: 1, s)
        let asked = try XCTUnwrap(second, "the second hole is asked for")
        let ms = Double(asked - seen) / 1e6, sinceFirst = Double(seen - firstAsk) / 1e6
        let line = String(format: "asked %.2f ms after it was seen (%.2f ms after the first ask)", ms, sinceFirst)
        // No clock seam: real time. The base's retry round is 8 ms after the first ask; a run whose setup took so long that
        // the hole was seen near it cannot tell the two apart, so it is skipped, not passed.
        try XCTSkipIf(sinceFirst > 3, "a busy machine: the hole was seen too late to tell the re-arm from the retry round: " + line)
        XCTAssertLessThan(ms, 4, line)  // the re-arm: 1...2 ms; without it: 8 - sinceFirst + 1
    }

    // MARK: a restart point given up during a repair wait

    private func piece(_ frame: UInt32, _ index: UInt16 = 0, count: UInt16 = 1, key: Bool = false, repair: Bool = false) -> VideoFragment {
        VideoFragment(frame: frame, index: index, count: count, key: key, repair: repair, captureNs: UInt64(frame), width: 64, height: 64,
                      payload: Data([1]))
    }

    private func decoded(_ f: VideoFragment) -> AssembledFrame {
        AssembledFrame(frame: f.frame, key: f.key, repair: f.repair, captureNs: f.captureNs, width: 64, height: 64, data: Data([1]))
    }

    private func waitForRepairs(_ n: Int, _ s: ClientSession) async -> Bool {
        let end = uptimeNs() + 300_000_000
        while uptimeNs() < end {
            if await s.stats().repairRequests >= n { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    /// A key frame decoded, then a frame lost (given up: `repair` asked, the first of the wait), then the repair frame
    /// itself half-arrives and is given up while its fragments (arriving every 4 ms) hold the 35 ms repeat: only the
    /// at-once re-ask can make a second `repair`. Returns the `repair`s sent after `before`.
    private func lostRestartPoint(_ s: ClientSession, key: UInt32, before: Int) async throws {
        await s.feed(piece(key, key: true))
        await s.frameDecoded(decoded(piece(key, key: true)))
        await s.feed(piece(key + 2))  // key + 1 is lost
        let first = await waitForRepairs(before + 1, s)
        XCTAssertTrue(first, "no repair asked for the lost frame")
        let end = uptimeNs() + 90_000_000
        while uptimeNs() < end {
            // The repair frame's fragments 1 and 2 of 3, again and again (the hole at 0 is seen, never filled).
            await s.feed(piece(key + 3, 1, count: 3, repair: true))
            await s.feed(piece(key + 3, 2, count: 3, repair: true))
            try await Task.sleep(for: .milliseconds(4))
        }
        let all = await s.stats().repairRequests
        XCTAssertEqual(all - before, 2, "the repair frame given up on its way is asked for again at once")
    }

    /// After a video restart the assembler's counts start at 0 again: a restart point given up during a repair wait is
    /// still asked for again at once, whatever the old stream's count was.
    func testARestartPointGivenUpAfterAVideoRestartIsAskedForAgainAtOnce() async throws {
        let s = ClientSession(identity: Identity(), name: "Test Client", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 5)
        try await lostRestartPoint(s, key: 1, before: 0)
        await s.restartVideo()
        let reset = await s.givenUpSeen
        XCTAssertEqual(reset, 0, "restartVideo leaves the old stream's count behind")
        let before = await s.stats().repairRequests
        try await lostRestartPoint(s, key: 10, before: before)
        await s.close()
    }
}

fileprivate extension ClientSession {
    /// A fragment arriving now: the time is taken inside the actor, as the receive path does (a time taken before the hop
    /// can be older than the timer's, and the repeat's `now - lastNs` would underflow).
    func feed(_ f: VideoFragment) { video(f, uptimeNs()) }
}
