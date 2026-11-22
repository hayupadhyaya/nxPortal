#if os(macOS)
import Foundation
import PortalKit

public enum TapEvent: Sendable {
    case hello(titleID: String, name: String)
    case video(frame: UInt32, captureNs: UInt64, width: UInt16, height: UInt16, mark: FrameMark, token: Int32, data: Data)
    case audio(captureNs: UInt64, pcm: Data)
    /// The game prepares before its first frame (phase, progress) -> .claude/host.md § tap-server
    case prepare(phase: UInt8, done: UInt32, total: UInt32)
    /// A message of a type this Host does not know, skipped by its length (the connection goes on).
    case skipped(type: UInt8)
    /// The connection is closed after it.
    case refused(String)
    case closed
}

public enum TapServerError: Error, Equatable {
    case pathTooLong
    /// The socket's folder is a link, not the user's own, or open to others.
    case unsafeFolder
    case system(String, Int32)
    /// `start()` after `stop()`: a server is used once.
    case stopped
}

/// Close-on-exec, so a launched game never inherits the descriptor.
func setCloseOnExec(_ fd: Int32) { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

/// Tap socket server: one game at a time -> .claude/host.md § tap-server
public actor TapServer {
    public nonisolated let events: AsyncStream<TapEvent>
    private let core: TapCore

    /// `requirePrivateFolder`: the socket's folder must be the user's own (a directory, not a link, mode 0700), made when missing,
    /// and stale sockets of dead Hosts are removed from it. Off for a path the caller owns (tests under the system temporary folder).
    public init(socketPath: String, requirePrivateFolder: Bool = false) {
        let (stream, continuation) = AsyncStream.makeStream(of: TapEvent.self, bufferingPolicy: .unbounded)
        events = stream
        core = TapCore(socketPath: socketPath, requirePrivateFolder: requirePrivateFolder, events: continuation)
    }

    public func start() throws { try core.start() }
    /// Nonisolated so callers keep their order without a suspension point.
    public nonisolated func send(_ message: TapMessage) { core.send(message) }
    /// Shuts down the current connection (its game reads EOF); the server keeps accepting.
    public nonisolated func disconnect() { core.disconnect() }
    public func stop() { core.stop() }
}

/// One accepted socket. `shutdown()` may come from any thread; only `close()` releases the fd, and only on the write queue.
final class TapConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()  // guards ready, closed (and orders shutdown against close)
    private var ready = false
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready && !closed }
    func markReady() { lock.lock(); ready = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

/// Owns the sockets and queues. Accept and read run on `loopQueue` (one game at a time by construction);
/// writes run on `writeQueue` so a slow game never blocks reading.
final class TapCore: @unchecked Sendable {
    private let path: String
    private let requirePrivateFolder: Bool
    private let events: AsyncStream<TapEvent>.Continuation
    private let loopQueue = DispatchQueue(label: "nxportal.tap.loop")
    private let writeQueue = DispatchQueue(label: "nxportal.tap.write")
    private let lock = NSLock()  // guards started, stopped, current, wakeWrite
    private var started = false
    private var stopped = false
    private var current: TapConnection?
    private var wakeWrite: Int32 = -1

    init(socketPath: String, requirePrivateFolder: Bool, events: AsyncStream<TapEvent>.Continuation) {
        path = socketPath
        self.requirePrivateFolder = requirePrivateFolder
        self.events = events
    }

    func start() throws {
        guard path.utf8.count <= 103 else { throw TapServerError.pathTooLong }
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw TapServerError.stopped }
        guard !started else { return }
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        if requirePrivateFolder {
            try Self.preparePrivateFolder(dir)
        } else if !FileManager.default.fileExists(atPath: dir) {
            do {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { throw TapServerError.system("mkdir", errno) }
        }
        unlink(path)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw TapServerError.system("socket", errno) }
        setCloseOnExec(listenFD)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { let e = errno; Darwin.close(listenFD); throw TapServerError.system("bind", e) }
        chmod(path, 0o600)
        guard listen(listenFD, 1) == 0 else { let e = errno; Darwin.close(listenFD); unlink(path); throw TapServerError.system("listen", e) }
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { let e = errno; Darwin.close(listenFD); unlink(path); throw TapServerError.system("pipe", e) }
        setCloseOnExec(pipeFDs[0])
        setCloseOnExec(pipeFDs[1])
        wakeWrite = pipeFDs[1]
        started = true
        let wakeRead = pipeFDs[0]
        loopQueue.async { self.acceptLoop(listenFD: listenFD, wakeRead: wakeRead) }
    }

    /// The folder exists as a directory (not a link) of this user with mode 0700, made when missing; sockets of Hosts that
    /// are gone are removed from it -> .claude/host.md § tap-server
    private static func preparePrivateFolder(_ dir: String) throws {
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard errno == ENOENT else { throw TapServerError.system("stat", errno) }
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { throw TapServerError.system("mkdir", errno) }
            guard lstat(dir, &st) == 0 else { throw TapServerError.system("stat", errno) }
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else {
            throw TapServerError.unsafeFolder
        }
        removeStaleSockets(in: dir)
    }

    /// `tap-<pid>-<n>.sock` of this user whose pid is not running (`ESRCH`); a pid that exists, even one we may not signal, stays.
    private static func removeStaleSockets(in dir: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            let parts = name.dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            guard name.hasSuffix(".sock"), parts.count == 3, parts[0] == "tap",
                  let pid = Int32(parts[1]), Int(parts[2]) != nil, pid > 0, pid != getpid() else { continue }
            if kill(pid, 0) == 0 || errno != ESRCH { continue }
            let path = dir + "/" + name
            var st = stat()
            if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() { unlink(path) }
        }
    }

    func send(_ message: TapMessage) {
        lock.lock(); let conn = current; lock.unlock()
        guard let conn, conn.isReady else { return }
        let data = message.encoded()
        writeQueue.async {
            guard !conn.isClosed else { return }
            if !Self.writeAll(conn.fd, data) { conn.shutdown() }
        }
    }

    func disconnect() {
        lock.lock(); let conn = current; lock.unlock()
        conn?.shutdown()
    }

    func stop() {
        lock.lock()
        let wasStarted = started
        let first = !stopped
        stopped = true
        if wasStarted && first { var b: UInt8 = 1; _ = write(wakeWrite, &b, 1) }
        lock.unlock()
        guard first else { return }
        if wasStarted { loopQueue.sync {} } else { events.finish() }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }

    private func acceptLoop(listenFD: Int32, wakeRead: Int32) {
        while true {
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let r = poll(&fds, 2, -1)
            if r < 0 { if errno == EINTR { continue }; break }
            if fds[1].revents != 0 { break }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; break }
            setCloseOnExec(fd)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let conn = TapConnection(fd: fd)
            lock.lock(); current = conn; lock.unlock()
            serve(conn, wakeRead: wakeRead)
        }
        Darwin.close(listenFD)
        unlink(path)
        lock.lock(); let w = wakeWrite; wakeWrite = -1; lock.unlock()
        Darwin.close(w)
        Darwin.close(wakeRead)
        events.finish()
    }

    /// Seconds a new connection has to say hello before it is closed.
    static let helloTimeout: UInt64 = 5

    /// Reads until the connection ends for any reason, then emits `.closed` exactly once.
    private func serve(_ conn: TapConnection, wakeRead: Int32) {
        var framer = TapFramer()
        var sawHello = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let helloDeadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + Self.helloTimeout * 1_000_000_000
        loop: while true {
            var fds = [pollfd(fd: conn.fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            var timeout: Int32 = -1
            if !sawHello {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if now >= helloDeadline { break }
                timeout = Int32((helloDeadline - now) / 1_000_000) + 1
            }
            let r = poll(&fds, 2, timeout)
            if r < 0 { if errno == EINTR { continue }; break }
            if r == 0 { continue }
            if fds[1].revents != 0 { break }
            let n = read(conn.fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            let messages: [TapMessage]
            do { messages = try framer.push(Data(buffer[0..<n])) { events.yield(.skipped(type: $0)) } } catch { break }
            for message in messages where !handle(message, conn, &sawHello) { break loop }
        }
        conn.shutdown()
        writeQueue.sync { conn.close() }
        lock.lock(); current = nil; lock.unlock()
        events.yield(.closed)
    }

    /// `false` ends the connection.
    private func handle(_ message: TapMessage, _ conn: TapConnection, _ sawHello: inout Bool) -> Bool {
        if !sawHello {
            guard case let .hello(version, titleID, name) = message else {
                events.yield(.refused("expected hello")); return false
            }
            guard version == ProtocolVersion.tap else {
                events.yield(.refused("tap protocol \(version), Host speaks \(ProtocolVersion.tap)")); return false
            }
            sawHello = true
            conn.markReady()
            events.yield(.hello(titleID: titleID, name: name))
            return true
        }
        switch message {
        case let .video(frame, captureNs, width, height, mark, token, data):
            events.yield(.video(frame: frame, captureNs: captureNs, width: width, height: height, mark: mark, token: token, data: data))
            return true
        case let .prepare(phase, done, total):
            events.yield(.prepare(phase: phase, done: done, total: total))
            return true
        case let .audio(captureNs, channels, pcm):
            guard channels == 2 else { events.yield(.refused("audio must be stereo")); return false }
            events.yield(.audio(captureNs: captureNs, pcm: pcm))
            return true
        default:
            return false
        }
    }
}
#endif
