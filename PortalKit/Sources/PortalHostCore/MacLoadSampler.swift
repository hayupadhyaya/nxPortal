#if os(macOS)
import Darwin
import Foundation

/// Reads the Mac's load with public interfaces (`MacLoad.swift` lists them); the only registry read is `GPUUtilisation`.
/// A value type: the previous tick counts live in it. -> .claude/host.md § load
public struct MacLoadSampler: LoadSampling {
    /// One CPU's cumulative tick counters (32 bit in the kernel).
    struct CPUTicks { var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 }

    /// Busy share in tenths of a percent over `range`; each delta is taken in 32 bits, so a counter that wrapped between
    /// two readings gives a small delta.
    static func share(_ now: [CPUTicks], _ before: [CPUTicks], _ range: Range<Int>) -> UInt16 {
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in range where i < now.count && i < before.count {
            let u = UInt64(now[i].user &- before[i].user), s = UInt64(now[i].system &- before[i].system)
            let n = UInt64(now[i].nice &- before[i].nice), idle = UInt64(now[i].idle &- before[i].idle)
            busy += u + s + n
            total += u + s + n + idle
        }
        guard total > 0 else { return 0 }
        return UInt16(min(1000, (Double(busy) / Double(total) * 1000).rounded()))
    }

    private let release: @Sendable (vm_address_t, Int) -> Void
    private let gpu: @Sendable () -> Double?
    private var previousCpu: [CPUTicks]?
    private var previousGame: (pid: Int32, cpuNs: UInt64, atNs: UInt64)?
    /// Logical CPUs of the efficiency level (the first indices), 0 with a single level.
    private let efficiencyCpus: Int
    private let timebase: mach_timebase_info_data_t

    /// `release` gives back an array `host_processor_info` returned (a test counts the calls); `gpu` is the registry read.
    init(release: @escaping @Sendable (vm_address_t, Int) -> Void = { _ = vm_deallocate(mach_task_self_, $0, vm_size_t($1)) },
         gpu: @escaping @Sendable () -> Double? = { GPUUtilisation.read() }) {
        self.release = release
        self.gpu = gpu
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb
        let levels = Self.sysctlInt("hw.nperflevels") ?? 1
        efficiencyCpus = levels >= 2 ? (Self.sysctlInt("hw.perflevel\(levels - 1).logicalcpu") ?? 0) : 0
    }

    public init() { self.init(release: { _ = vm_deallocate(mach_task_self_, $0, vm_size_t($1)) }, gpu: { GPUUtilisation.read() }) }

    public mutating func sample(gamePID: Int32?, now: UInt64) -> MacLoadReading {
        var r = MacLoadReading()
        r.thermal = UInt8(ProcessInfo.processInfo.thermalState.rawValue)
        switch Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 2: r.pressure = 1
        case 4: r.pressure = 2
        default: r.pressure = 0
        }
        readCpu(into: &r)
        readMemory(into: &r)
        r.gpu = gpu().map { UInt16(clamping: Int(($0 * 10).rounded())) }.map { min($0, 1000) }
        readGame(gamePID, now: now, into: &r)
        return r
    }

    // MARK: CPU

    private mutating func readCpu(into r: inout MacLoadReading) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return }
        defer { release(vm_address_t(bitPattern: info), Int(infoCount) * MemoryLayout<integer_t>.size) }
        let stride = Int(CPU_STATE_MAX)
        var now: [CPUTicks] = []
        for cpu in 0..<Int(count) {
            let base = cpu * stride
            guard base + stride <= Int(infoCount) else { break }
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            now.append(CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)))
        }
        defer { previousCpu = now }
        guard let before = previousCpu, before.count == now.count else { return }
        let split = min(efficiencyCpus, now.count)
        r.cpuTotal = Self.share(now, before, 0..<now.count)
        r.cpuEff = split > 0 ? Self.share(now, before, 0..<split) : 0
        r.cpuPerf = split < now.count ? Self.share(now, before, split..<now.count) : 0
    }

    // MARK: memory

    private func readMemory(into r: inout MacLoadReading) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if status == KERN_SUCCESS {
            let pages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count) &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
            r.memUsedMiB = UInt32(clamping: pages &* UInt64(pageSize) / 1_048_576)
        }
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &bytes, &size, nil, 0) == 0 { r.memTotalMiB = UInt32(clamping: bytes / 1_048_576) }
        if r.memUsedMiB > r.memTotalMiB { r.memUsedMiB = r.memTotalMiB }
    }

    // MARK: the game

    private mutating func readGame(_ pid: Int32?, now: UInt64, into r: inout MacLoadReading) {
        guard let pid else { previousGame = nil; return }
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard status == 0 else { previousGame = nil; return }
        r.gameAlive = true
        r.gameMemMiB = UInt32(clamping: usage.ri_phys_footprint / 1_048_576)
        let cpuNs = (usage.ri_user_time &+ usage.ri_system_time) &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        defer { previousGame = (pid, cpuNs, now) }
        if let p = previousGame, p.pid == pid, now > p.atNs, cpuNs >= p.cpuNs {
            r.gameCpuCentiCores = UInt32(clamping: Int((Double(cpuNs - p.cpuNs) / Double(now - p.atNs) * 100).rounded()))
        }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var n = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &n, nil, 0) == 0 ? Int(v) : nil
    }
}
#endif
