#if os(macOS)
import Foundation

/// The app's log file: one line per call, a UTC time in front; at `limit` bytes the file moves to `<name>.1` (replacing an
/// older one) and a new one begins -> .claude/host.md § app
public final class HostLogFile: @unchecked Sendable {  // lock-guarded
    private let url: URL
    private let limit: Int
    private let lock = NSLock()  // guards the file
    private let clock: @Sendable () -> Date

    public init(url: URL, limit: Int = 1_000_000, clock: @escaping @Sendable () -> Date = Date.init) {
        self.url = url; self.limit = limit; self.clock = clock
    }

    /// A failure to write is not reported anywhere: a log must never stop the Host.
    public func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: clock())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        lock.withLock {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0, size + data.count > limit {
                let older = url.appendingPathExtension("1")
                try? fm.removeItem(at: older)
                do { try fm.moveItem(at: url, to: older) } catch { try? fm.removeItem(at: url) }  // never left to grow
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
#endif
