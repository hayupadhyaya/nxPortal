import AppKit
import Darwin
import PortalHostModel

/// A second launch of the same bundle exits at once: the oldest instance stays.
enum SingleInstance {
    /// Whether this process should exit: another one runs this bundle (the same bundle ID, or the same executable: a binary
    /// started by path has no bundle ID in Launch Services) and `InstanceRule` says this one is the one to go. Nothing else has
    /// been opened when this is asked.
    static func shouldExit() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        var others = Set<pid_t>()  // a process already in its stop cannot be told from a running one: it still counts
        if let id = Bundle.main.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != me && !app.isTerminated {
                others.insert(app.processIdentifier)
            }
        }
        if let mine = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
            for pid in processes() where pid != me && path(of: pid) == mine { others.insert(pid) }
        }
        return InstanceRule.shouldExit(me: .init(pid: me, startedAt: startTime(of: me)),
                                       others: others.map { .init(pid: $0, startedAt: startTime(of: $0)) })
    }

    /// When the process started, in microseconds since 1970; nil when the system does not say.
    private static func startTime(of pid: pid_t) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
    }

    private static func processes() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(filled, 0))).filter { $0 > 0 })
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            .resolvingSymlinksInPath().path
    }
}
