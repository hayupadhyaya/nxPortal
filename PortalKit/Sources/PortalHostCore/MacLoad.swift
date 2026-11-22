#if os(macOS)
import Foundation

/// What `MacLoadSampler` reads once a second (numbers only: no process names, paths or addresses) -> .claude/host.md § load
/// Interfaces checked against the macOS SDK headers and this Mac before use (each line: the finding):
/// - `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`: per logical CPU four cumulative tick counts (user, system, idle, nice);
///   the returned array is the caller's to `vm_deallocate` (`MacLoadSampler.release`).
/// - `host_statistics64(HOST_VM_INFO64)` with `HOST_VM_INFO64_COUNT`: page counts in `host_page_size` units (16 KiB here);
///   "used" = internal - purgeable + wired + compressor pages (Activity Monitor's App + Wired + Compressed).
/// - `proc_pid_rusage(pid, RUSAGE_INFO_V6)`: `ri_user_time` + `ri_system_time` in mach ticks (-> ns with
///   `mach_timebase_info`), `ri_phys_footprint` in bytes; non-zero return for a pid that is gone.
/// - `sysctl hw.memsize` (bytes); `kern.memorystatus_vm_pressure_level` 1 normal, 2 warning, 4 critical (-> 0, 1, 2).
/// - `sysctl hw.nperflevels` can be 3 (a chip with a "super" level): level 0 is the fastest, the LAST level is the efficiency
///   cluster, every level before it counts as performance; with one level everything is performance.
/// - Which logical CPU belongs to which level has no public query: efficiency CPUs are the first indices. MEASURED with this
///   sampler on an Apple silicon Mac with three levels: three spinning processes at normal priority read performance about
///   51 to 55 %, efficiency about 3 %; the same under `taskpolicy -b` (background work stays on the efficiency cores) read
///   performance 0 to 1 %, efficiency about 55 to 57 % (`.claude/host.md § load`). The totals never depend on it.
/// - `ioreg -r -c AGXAccelerator`: `PerformanceStatistics` holds "Device Utilization %" (integer percent) -> `GPUUtilisation`.
public struct MacLoadReading: Equatable, Sendable {
    /// `ProcessInfo.ThermalState` 0 nominal ... 3 critical.
    public var thermal: UInt8 = 0
    /// 0 normal, 1 warning, 2 critical.
    public var pressure: UInt8 = 0
    /// Tenths of a percent, 0...1000.
    public var cpuTotal: UInt16 = 0, cpuPerf: UInt16 = 0, cpuEff: UInt16 = 0
    /// Tenths of a percent; nil = the Mac gives no GPU reading.
    public var gpu: UInt16?
    public var memUsedMiB: UInt32 = 0, memTotalMiB: UInt32 = 0
    public var gameAlive = false
    /// 100 = one core busy.
    public var gameCpuCentiCores: UInt32 = 0
    public var gameMemMiB: UInt32 = 0
    public init() {}
}

public protocol LoadSampling: Sendable {
    /// One reading; CPU shares are over the time since the previous call (the first call has nothing to compare with and
    /// reads 0 for them). `gamePID` nil or gone: `gameAlive` false. `now`: uptime ns.
    mutating func sample(gamePID: Int32?, now: UInt64) -> MacLoadReading
}

/// Runs the sampler off the service's actor: a slow read (the registry, a busy Mac) occupies this actor only, so no video or
/// control message waits for it -> .claude/host.md § load
actor LoadRunner {
    private var sampler: any LoadSampling
    init(_ sampler: any LoadSampling) { self.sampler = sampler }
    func sample(pid: Int32?, now: UInt64) -> MacLoadReading { sampler.sample(gamePID: pid, now: now) }
}
#endif
