#if os(macOS)
import XCTest
import Foundation
@testable import PortalHostModel

/// Which instance stays, and the one stop -> .claude/host.md § app
@MainActor
final class OneSurvivorTests: XCTestCase {
    private func i(_ pid: Int32, _ start: Int64?) -> InstanceRule.Instance { .init(pid: pid, startedAt: start) }

    func testTheOldestInstanceStaysWhateverItsPid() {
        // After a pid wrap the running Host can have the higher pid: it stays, the newcomer exits.
        XCTAssertTrue(InstanceRule.shouldExit(me: i(800, 2_000), others: [i(90_000, 1_000)]))
        XCTAssertFalse(InstanceRule.shouldExit(me: i(90_000, 1_000), others: [i(800, 2_000)]))
        XCTAssertFalse(InstanceRule.shouldExit(me: i(100, 1_000), others: []))
        XCTAssertTrue(InstanceRule.shouldExit(me: i(300, 5_000), others: [i(400, 6_000), i(100, 4_000)]))
    }

    /// Two starts that see each other: exactly one survives, whichever order they started in.
    func testTwoStartsThatSeeEachOtherLeaveOne() {
        for (a, b) in [(i(500, 1_000), i(501, 1_001)), (i(501, 1_000), i(500, 1_001)), (i(500, 1_000), i(501, 1_000)), (i(501, 1_000), i(500, 1_000))] {
            let exits = [InstanceRule.shouldExit(me: a, others: [b]), InstanceRule.shouldExit(me: b, others: [a])]
            XCTAssertEqual(exits.filter { !$0 }.count, 1, "\(a) \(b) \(exits)")
        }
    }

    func testEqualStartTimesFallBackToThePid() {
        XCTAssertTrue(InstanceRule.shouldExit(me: i(200, 1_000), others: [i(100, 1_000)]))
        XCTAssertFalse(InstanceRule.shouldExit(me: i(100, 1_000), others: [i(200, 1_000)]))
    }

    /// Never two Hosts: an instance whose start time cannot be read counts as older, and one that cannot read its own leaves.
    func testAnUnreadableStartTimeCountsAsOlder() {
        XCTAssertTrue(InstanceRule.shouldExit(me: i(800, 2_000), others: [i(90_000, nil)]))
        XCTAssertTrue(InstanceRule.shouldExit(me: i(800, nil), others: [i(90_000, 1_000)]))
        XCTAssertFalse(InstanceRule.shouldExit(me: i(800, nil), others: []))
    }

    func testTheFinishingStepRunsOnceHoweverManyAskedAndWhicheverEndsFirst() async {
        var count = 0
        let gate = ShutdownGate(limit: 0.2, finally: { count += 1 })
        await gate.run { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }  // ends by the limit
        await gate.run { }
        XCTAssertEqual(count, 1)
        let quick = ShutdownGate(limit: 5, finally: { count += 1 })
        async let a: Void = quick.run { }
        async let b: Void = quick.run { }
        _ = await (a, b)
        try? await Task.sleep(nanoseconds: 100_000_000)  // the one fixed wait: proves nothing runs again
        XCTAssertEqual(count, 2)
    }

    private final class Counter {
        var started = 0, finished = 0
    }

    func testTwoStopsRunTheWorkOnceAndBothWaitForIt() async {
        let gate = ShutdownGate(limit: 5)
        let counter = Counter()
        var release: CheckedContinuation<Void, Never>?
        let work: @MainActor () async -> Void = {
            counter.started += 1
            await withCheckedContinuation { release = $0 }
            counter.finished += 1
        }
        var returned = 0
        let first = Task { await gate.run(work); returned += 1 }
        while release == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        let second = Task { await gate.run(work); returned += 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)  // the one fixed wait: proves the second request does not return early
        XCTAssertEqual(returned, 0, "a second request returned while the stop was under way")
        XCTAssertEqual(counter.started, 1)
        release?.resume()
        await first.value; await second.value
        XCTAssertEqual(returned, 2)
        XCTAssertEqual(counter.started, 1)
        XCTAssertEqual(counter.finished, 1)
    }

    func testAStopThatNeverEndsIsLeftAfterTheLimit() async {
        let gate = ShutdownGate(limit: 0.3)
        let t0 = Date()
        await gate.run { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
        let took = Date().timeIntervalSince(t0)
        XCTAssertGreaterThanOrEqual(took, 0.25)
        XCTAssertLessThan(took, 3)
        await gate.run { XCTFail("the work ran twice") }  // already begun: joins, returns at once
    }
}
#endif
