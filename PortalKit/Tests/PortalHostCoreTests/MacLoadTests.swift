#if os(macOS)
import XCTest
import Foundation
@testable import PortalHostCore

final class MacLoadTests: XCTestCase {
    private func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private func memsizeMiB() -> UInt32 {
        var bytes: UInt64 = 0
        var n = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &bytes, &n, nil, 0)
        return UInt32(bytes / 1_048_576)
    }

    /// Two samples a little apart: the second has something to compare with.
    private func settled(_ s: inout MacLoadSampler, pid: Int32? = nil) -> MacLoadReading {
        _ = s.sample(gamePID: pid, now: nowNs())
        Thread.sleep(forTimeInterval: 0.15)
        return s.sample(gamePID: pid, now: nowNs())
    }

    func testTheMachineNumbersAreInRange() {
        var s = MacLoadSampler()
        let r = settled(&s)
        for v in [r.cpuTotal, r.cpuPerf, r.cpuEff] { XCTAssertLessThanOrEqual(v, 1000) }
        XCTAssertEqual(r.memTotalMiB, memsizeMiB())
        XCTAssertGreaterThan(r.memUsedMiB, 0)
        XCTAssertLessThanOrEqual(r.memUsedMiB, r.memTotalMiB)
        XCTAssertLessThanOrEqual(r.pressure, 2)
        XCTAssertLessThanOrEqual(r.thermal, 3)
        if let g = r.gpu { XCTAssertLessThanOrEqual(g, 1000) }
    }

    func testBusyThreadsRaiseTheCpuShare() {
        var s = MacLoadSampler()
        _ = s.sample(gamePID: nil, now: nowNs())
        let stop = Atomic()
        let threads = (0..<ProcessInfo.processInfo.activeProcessorCount).map { _ in
            Thread { var x = 1.0; while !stop.value { x = x * 1.0000001 + 0.1 } ; _ = x }
        }
        threads.forEach { $0.start() }
        Thread.sleep(forTimeInterval: 0.4)
        let r = s.sample(gamePID: nil, now: nowNs())
        stop.value = true
        XCTAssertGreaterThan(r.cpuTotal, 300, "every core spinning for 0.4 s reads well above idle: \(r.cpuTotal)")
    }

    func testTheGamesOwnProcessIsAliveWithMemoryAndCpu() {
        var s = MacLoadSampler()
        let pid = ProcessInfo.processInfo.processIdentifier
        _ = s.sample(gamePID: pid, now: nowNs())
        let end = Date().addingTimeInterval(0.2)
        var x = 1.0
        while Date() < end { x = x * 1.0000001 + 0.1 }
        XCTAssertGreaterThan(x, 0)
        let r = s.sample(gamePID: pid, now: nowNs())
        XCTAssertTrue(r.gameAlive)
        XCTAssertGreaterThan(r.gameMemMiB, 0)
        XCTAssertGreaterThanOrEqual(r.gameCpuCentiCores, 50, "a busy loop of 200 ms on one core")
    }

    func testAMissingProcessIsNotAlive() {
        var s = MacLoadSampler()
        let r = s.sample(gamePID: 2_000_000_000, now: nowNs())
        XCTAssertFalse(r.gameAlive)
        XCTAssertEqual(r.gameCpuCentiCores, 0)
        XCTAssertEqual(r.gameMemMiB, 0)
        XCTAssertFalse(s.sample(gamePID: nil, now: nowNs()).gameAlive)
    }

    func testAPidThatDisappearsStartsFreshWhenItComesBack() {
        var s = MacLoadSampler()
        let pid = ProcessInfo.processInfo.processIdentifier
        _ = s.sample(gamePID: pid, now: nowNs())
        _ = s.sample(gamePID: nil, now: nowNs())
        let r = s.sample(gamePID: pid, now: nowNs())
        XCTAssertEqual(r.gameCpuCentiCores, 0, "no earlier reading of this run to compare with")
        XCTAssertTrue(r.gameAlive)
    }

    func testThirtySamplesReleaseEveryProcessorArrayTheyTook() {
        let released = Counter()
        var s = MacLoadSampler(release: { address, size in
            released.add(size)
            _ = vm_deallocate(mach_task_self_, address, vm_size_t(size))
        }, gpu: { nil })
        for _ in 0..<30 { _ = s.sample(gamePID: ProcessInfo.processInfo.processIdentifier, now: nowNs()) }
        XCTAssertEqual(released.count, 30, "one array taken and given back per sample")
        XCTAssertGreaterThan(released.bytes, 0)
    }

    func testNoGPUReadingIsReportedAsNil() {
        var s = MacLoadSampler(gpu: { nil })
        XCTAssertNil(settled(&s).gpu)
        var t = MacLoadSampler(gpu: { 78.34 })
        XCTAssertEqual(settled(&t).gpu, 783)
        var u = MacLoadSampler(gpu: { 250 })
        XCTAssertEqual(settled(&u).gpu, 1000, "clamped")
    }

    /// The kernel's tick counters are 32 bit: a counter that wrapped between two readings gives a small delta.
    func testAWrappedTickCounterGivesASmallDelta() {
        let before = [MacLoadSampler.CPUTicks(user: UInt32.max - 10, system: 0, idle: UInt32.max - 5, nice: 0)]
        let now = [MacLoadSampler.CPUTicks(user: 39, system: 0, idle: 94, nice: 0)]  // user +50, idle +100
        XCTAssertEqual(MacLoadSampler.share(now, before, 0..<1), 333, "50 busy of 150")
        XCTAssertEqual(MacLoadSampler.share(before, before, 0..<1), 0, "no ticks, no share")
    }

    func testTheRegistryReadIsAPercentOrAbsent() {
        if let v = GPUUtilisation.read() { XCTAssertTrue((0.0...100.0).contains(v)) }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()  // guards n, b
        private var n = 0, b = 0
        func add(_ bytes: Int) { lock.lock(); n += 1; b += bytes; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        var bytes: Int { lock.lock(); defer { lock.unlock() }; return b }
    }
    final class Atomic: @unchecked Sendable {
        private let lock = NSLock()  // guards flag
        private var flag = false
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return flag } set { lock.lock(); flag = newValue; lock.unlock() } }
    }
}
#endif
