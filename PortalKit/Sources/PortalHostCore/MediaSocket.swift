#if os(macOS)
import Foundation
import os
import PortalKit

/// Counts datagrams the socket failed to send; `reportDue` hands the count out at most once a second.
struct MediaDropCounter {
    private var count = 0
    private var lastReportNs: UInt64?

    mutating func dropped() { count += 1 }

    /// The drops since the last report when there are any and a second has passed; resets the count.
    mutating func reportDue(nowNs: UInt64) -> Int? {
        let last = lastReportNs ?? nowNs
        lastReportNs = last
        guard count > 0, nowNs &- last >= 1_000_000_000 else { return nil }
        defer { count = 0; lastReportNs = nowNs }
        return count
    }
}

/// A datagram's source (the raw `sockaddr` bytes) and the address of this Mac it arrived at: answers leave from there.
struct UDPAddress: Equatable, Sendable {
    let bytes: Data
    /// nil: the kernel picks the source (a test socket, or no packet info on the datagram).
    var local: LocalAddress? = nil
}

/// The address of this Mac a datagram arrived at (packet info) -> .claude/host.md § service
struct LocalAddress: Equatable, Sendable {
    /// 4 bytes (IPv4) or 16 (IPv6).
    let ip: Data
    /// The arrival interface for a link-local IPv6 address (its scope); 0 otherwise (routing picks the interface).
    let interface: UInt32
}

struct InboundDatagram: Sendable { let data: Data; let from: UDPAddress }

/// The service's UDP sockets: one IPv4 and one IPv6-only on the same ephemeral port, POSIX -> .claude/host.md § service
/// Each answer leaves from the address its device sent to (packet info out, as it came in): a device's connected
/// media flow drops anything from another address of the Mac. Two sockets because macOS ignores an IPv4-mapped source
/// given to a dual-stack socket. Receives on its own thread into `datagrams`; sends never block (`transmit` reports
/// a full buffer; real failures are counted).
final class MediaSocket: @unchecked Sendable, MediaTransmitting {
    let datagrams: AsyncStream<InboundDatagram>
    private let continuation: AsyncStream<InboundDatagram>.Continuation
    private let lock = NSLock()  // guards fd4, fd6, wakeWrite, running, stopped, drops, sendControl
    private var drops = MediaDropCounter()
    private static let log = Logger(subsystem: "nxportal", category: "media")
    private var fd4: Int32 = -1
    private var fd6: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var running = false
    private var stopped = false
    private let loopDone = DispatchGroup()
    /// The packet info of one answer, built in place under `lock`: no allocation per datagram.
    private let sendControl = UnsafeMutableRawPointer.allocate(byteCount: Cmsg.space(MemoryLayout<in6_pktinfo>.size), alignment: 8)

    init() {
        (datagrams, continuation) = AsyncStream.makeStream(of: InboundDatagram.self, bufferingPolicy: .unbounded)
    }

    deinit { sendControl.deallocate() }

    /// Binds both sockets to one port and starts receiving; returns the port.
    func start() throws -> UInt16 {
        var attempt = 0
        while true {
            attempt += 1
            let s6 = try Self.makeSocket(AF_INET6)
            guard let port = Self.bindAny(s6, family: AF_INET6, port: 0) else { let e = errno; close(s6); throw HostServiceError.system("bind", e) }
            let s4: Int32
            do { s4 = try Self.makeSocket(AF_INET) } catch { close(s6); throw error }
            if Self.bindAny(s4, family: AF_INET, port: port) == nil {
                let e = errno
                close(s4); close(s6)
                if e == EADDRINUSE, attempt < 16 { continue }  // the IPv6 port is taken for IPv4: another port
                throw HostServiceError.system("bind", e)
            }
            try run(s4, s6)
            return port
        }
    }

    private func run(_ s4: Int32, _ s6: Int32) throws {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { let e = errno; close(s4); close(s6); throw HostServiceError.system("pipe", e) }
        pipeFDs.forEach(setCloseOnExec)
        lock.lock()
        fd4 = s4; fd6 = s6
        wakeWrite = pipeFDs[1]
        running = true
        lock.unlock()
        loopDone.enter()
        let wakeRead = pipeFDs[0]
        Thread.detachNewThread { self.receiveLoop(s4, s6, wakeRead: wakeRead); close(wakeRead); self.loopDone.leave() }
    }

    /// Non-blocking, 4 MB buffers, the interactive video class, packet info on receive; IPv6 only on the IPv6 socket.
    private static func makeSocket(_ family: Int32) throws -> Int32 {
        let s = socket(family, SOCK_DGRAM, 0)
        guard s >= 0 else { throw HostServiceError.system("socket", errno) }
        setCloseOnExec(s)
        var on: Int32 = 1
        var size: Int32 = 4 << 20
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        if family == AF_INET6 { setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &on, intSize) }
        setsockopt(s, SOL_SOCKET, SO_SNDBUF, &size, intSize)
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, intSize)
        // Interactive video traffic class; a refusal costs priority only, so it is logged once and ignored.
        var serviceType = Int32(NET_SERVICE_TYPE_VI)
        if setsockopt(s, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, intSize) != 0 {
            log.error("media: could not set the traffic class (errno \(errno))")
        }
        // Without packet info the kernel picks each answer's source (the fault this guards against): logged, not fatal.
        let pktinfo = family == AF_INET ? setsockopt(s, IPPROTO_IP, IP_RECVPKTINFO, &on, intSize)
                                        : setsockopt(s, IPPROTO_IPV6, Cmsg.ipv6RecvPktinfo, &on, intSize)
        if pktinfo != 0 { log.error("media: no packet info on receive (errno \(errno))") }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        return s
    }

    /// The wildcard address at `port` (0 = any); returns the bound port, nil on failure (errno set).
    private static func bindAny(_ s: Int32, family: Int32, port: UInt16) -> UInt16? {
        var storage = sockaddr_storage()
        var len: socklen_t
        if family == AF_INET6 {
            len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutableBytes(of: &storage) { raw in
                let a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
                a.pointee.sin6_len = UInt8(len); a.pointee.sin6_family = sa_family_t(AF_INET6)
                a.pointee.sin6_addr = in6addr_any; a.pointee.sin6_port = port.bigEndian
            }
        } else {
            len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutableBytes(of: &storage) { raw in
                let a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
                a.pointee.sin_len = UInt8(len); a.pointee.sin_family = sa_family_t(AF_INET)
                a.pointee.sin_addr.s_addr = INADDR_ANY; a.pointee.sin_port = port.bigEndian
            }
        }
        let ok = withUnsafeMutableBytes(of: &storage) { raw in
            let sa = raw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            return bind(s, sa, len) == 0 && getsockname(s, sa, &len) == 0
        }
        guard ok else { return nil }
        // sin_port and sin6_port sit at the same offset (2).
        return withUnsafeBytes(of: &storage) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
    }

    func send(_ data: Data, to address: UDPAddress) { _ = transmit(data, to: address) }

    /// `.wouldBlock` (a full buffer or interface queue) is the caller's to retry; only other failures are counted.
    /// The source is the address the device sent to (`address.local`).
    func transmit(_ data: Data, to address: UDPAddress) -> TransmitOutcome {
        lock.lock()
        let v4 = address.bytes.count > 1 && address.bytes[address.bytes.startIndex + 1] == UInt8(AF_INET)
        let fd = v4 ? fd4 : fd6
        guard fd >= 0 else { lock.unlock(); return .failed }
        let controlLength = address.local.map { Cmsg.write($0, v4: v4, into: sendControl) } ?? 0
        let sent = address.bytes.withUnsafeBytes { a in
            data.withUnsafeBytes { d in
                var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: d.baseAddress), iov_len: d.count)
                return withUnsafeMutablePointer(to: &iov) { iovp in
                    var msg = msghdr(msg_name: UnsafeMutableRawPointer(mutating: a.baseAddress), msg_namelen: socklen_t(a.count),
                                     msg_iov: iovp, msg_iovlen: 1,
                                     msg_control: controlLength > 0 ? sendControl : nil, msg_controllen: socklen_t(controlLength),
                                     msg_flags: 0)
                    return sendmsg(fd, &msg, 0)
                }
            }
        }
        var outcome = TransmitOutcome.sent
        if sent < 0 {
            let e = errno
            if e == EAGAIN || e == ENOBUFS { outcome = .wouldBlock } else { outcome = .failed; drops.dropped() }
        }
        let report = drops.reportDue(nowNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        lock.unlock()
        if let report { Self.log.error("media: \(report) datagrams not sent (send failed)") }
        return outcome
    }

    /// Idempotent; the stream finishes.
    func stop() {
        lock.lock()
        let wasRunning = running && !stopped
        stopped = true
        if wasRunning { var b: UInt8 = 1; _ = write(wakeWrite, &b, 1) }
        lock.unlock()
        if wasRunning { loopDone.wait() }
        lock.lock()
        if fd4 >= 0 { close(fd4); fd4 = -1 }
        if fd6 >= 0 { close(fd6); fd6 = -1 }
        if wakeWrite >= 0 { close(wakeWrite); wakeWrite = -1 }
        lock.unlock()
        continuation.finish()
    }

    /// The buffer holds one byte more than a datagram may: a longer one is dropped before it is opened.
    private func receiveLoop(_ s4: Int32, _ s6: Int32, wakeRead: Int32) {
        let size = Wire.maxDatagram + 1
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        let controlSize = 128
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)
        defer { buffer.deallocate(); control.deallocate() }
        var fds = [pollfd(fd: s4, events: Int16(POLLIN), revents: 0), pollfd(fd: s6, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while true {
            for i in fds.indices { fds[i].revents = 0 }
            let r = poll(&fds, 3, -1)
            if r < 0 { if errno == EINTR { continue }; return }
            if fds[2].revents != 0 { return }
            for i in 0..<2 {
                let s = fds[i].fd
                while true {
                    var from = sockaddr_storage()
                    let (n, fromLen, controlLen): (Int, socklen_t, Int) = withUnsafeMutableBytes(of: &from) { name in
                        var iov = iovec(iov_base: buffer, iov_len: size)
                        return withUnsafeMutablePointer(to: &iov) { iovp in
                            var msg = msghdr(msg_name: name.baseAddress, msg_namelen: socklen_t(name.count), msg_iov: iovp, msg_iovlen: 1,
                                             msg_control: control, msg_controllen: socklen_t(controlSize), msg_flags: 0)
                            let n = recvmsg(s, &msg, 0)
                            return (n, msg.msg_namelen, Int(msg.msg_controllen))
                        }
                    }
                    if n < 0 { break }  // EAGAIN: drained
                    guard n > 0, n <= Wire.maxDatagram else { continue }
                    var address = withUnsafeBytes(of: &from) { UDPAddress(bytes: Data($0.prefix(Int(fromLen)))) }
                    address.local = Cmsg.arrival(control, length: controlLen)
                    continuation.yield(InboundDatagram(data: Data(bytes: buffer, count: n), from: address))
                }
            }
        }
    }
}

/// Packet-info control messages, laid out by hand (the `CMSG_*` macros are not visible to Swift).
enum Cmsg {
    /// RFC 3542 values, which the Darwin module exposes only under `__APPLE_USE_RFC_3542`.
    static let ipv6RecvPktinfo: Int32 = 61
    static let ipv6Pktinfo: Int32 = 46
    /// `struct cmsghdr`: length, level, type (3 x 32 bits); data and headers are 4-byte aligned.
    static let header = 12
    static func align(_ n: Int) -> Int { (n + 3) & ~3 }
    static func space(_ n: Int) -> Int { header + align(n) }

    /// The arrival address in the first packet-info message, if any.
    static func arrival(_ control: UnsafeRawPointer, length: Int) -> LocalAddress? {
        var offset = 0
        while offset + header <= length {
            let len = Int(control.load(fromByteOffset: offset, as: UInt32.self))
            let level = control.load(fromByteOffset: offset + 4, as: Int32.self)
            let type = control.load(fromByteOffset: offset + 8, as: Int32.self)
            guard len >= header, offset + len <= length else { return nil }
            let data = control + offset + header
            if level == IPPROTO_IP, type == IP_PKTINFO, len >= header + MemoryLayout<in_pktinfo>.size {
                var a = data.loadUnaligned(as: in_pktinfo.self).ipi_addr
                return LocalAddress(ip: Data(bytes: &a, count: 4), interface: 0)
            }
            if level == IPPROTO_IPV6, type == ipv6Pktinfo, len >= header + MemoryLayout<in6_pktinfo>.size {
                let info = data.loadUnaligned(as: in6_pktinfo.self)
                var a = info.ipi6_addr
                let ip = Data(bytes: &a, count: 16)
                let linkLocal = ip[0] == 0xfe && ip[1] & 0xc0 == 0x80
                return LocalAddress(ip: ip, interface: linkLocal ? info.ipi6_ifindex : 0)
            }
            offset += align(len)
        }
        return nil
    }

    /// One packet-info message that sets `local` as the source; returns its length (0: the family does not match).
    static func write(_ local: LocalAddress, v4: Bool, into control: UnsafeMutableRawPointer) -> Int {
        let level: Int32, type: Int32, size: Int
        if v4 {
            guard local.ip.count == 4 else { return 0 }
            // `ipi_spec_dst` is the source; interface 0: routing picks it (a forced loopback interface loses the answer).
            var info = in_pktinfo()
            withUnsafeMutableBytes(of: &info.ipi_spec_dst) { dst in local.ip.withUnsafeBytes { dst.copyMemory(from: $0) } }
            (level, type, size) = (IPPROTO_IP, IP_PKTINFO, MemoryLayout<in_pktinfo>.size)
            (control + header).storeBytes(of: info, as: in_pktinfo.self)
        } else {
            guard local.ip.count == 16 else { return 0 }
            var info = in6_pktinfo()
            withUnsafeMutableBytes(of: &info.ipi6_addr) { dst in local.ip.withUnsafeBytes { dst.copyMemory(from: $0) } }
            info.ipi6_ifindex = local.interface
            (level, type, size) = (IPPROTO_IPV6, ipv6Pktinfo, MemoryLayout<in6_pktinfo>.size)
            (control + header).storeBytes(of: info, as: in6_pktinfo.self)
        }
        control.storeBytes(of: UInt32(header + size), as: UInt32.self)
        control.storeBytes(of: level, toByteOffset: 4, as: Int32.self)
        control.storeBytes(of: type, toByteOffset: 8, as: Int32.self)
        return space(size)
    }
}
#endif
