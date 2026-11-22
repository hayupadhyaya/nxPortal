#if os(macOS)
import XCTest
import Foundation
import PortalTestSupport

/// A client socket and a Host socket with a shaper between them. The Host answers to wherever the shaper's `hi` came from.
private final class Rig: @unchecked Sendable {
    struct Arrival { let number: Int; let bytes: Int; let atNs: UInt64 }

    let shaper: LinkShaper
    private let client: Int32
    private let host: Int32
    private let shaperPort: UInt16
    private var hostSeesClient = sockaddr_in()
    private let lock = NSLock()  // guards arrivals, running
    private var arrivals: [Arrival] = []
    private var running = true
    private let reader = DispatchGroup()

    init(_ profile: LinkProfile, seed: UInt64 = 7) throws {
        let c = Rig.makeSocket(), h = Rig.makeSocket()
        var hostAddr = sockaddr_in()
        hostAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        hostAddr.sin_family = sa_family_t(AF_INET)
        hostAddr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &hostAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(h, $0, len); return getsockname(h, $0, &len) }
        }
        client = c; host = h
        shaper = LinkShaper(profile: profile, seed: seed, to: ("127.0.0.1", UInt16(bigEndian: hostAddr.sin_port)))
        shaperPort = try shaper.start()
        reader.enter()
        Thread.detachNewThread { self.read(); self.reader.leave() }
    }

    private static func makeSocket() -> Int32 {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        var size: Int32 = 8 << 20
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return s
    }

    private func sendTo(_ fd: Int32, port: UInt16, _ bytes: [UInt8]) {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        a.sin_port = port.bigEndian
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// The client's datagram numbered `n` (4 bytes big-endian, padded to `size`), sent to the shaper.
    func clientSends(_ n: Int, size: Int = 64) {
        sendTo(client, port: shaperPort, Rig.packet(n, size))
    }

    static func packet(_ n: Int, _ size: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: max(size, 4))
        for i in 0..<4 { b[i] = UInt8((n >> (8 * (3 - i))) & 0xFF) }
        return b
    }

    /// Reads on the Host socket until a datagram came (the shaper's address for the client).
    func waitHostHears(timeout: TimeInterval = 2) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < end {
            var from = sockaddr_in()
            var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(host, &buf, buf.count, 0, $0, &fl) }
            }
            if n > 0 { hostSeesClient = from; return true }
        }
        return false
    }

    /// The Host sends datagram `n` of `size` bytes back through the shaper.
    func hostSends(_ n: Int, size: Int) {
        sendTo(host, port: UInt16(bigEndian: hostSeesClient.sin_port), Rig.packet(n, size))
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while lock.withLock({ running }) {
            let n = recv(client, &buf, buf.count, 0)
            guard n >= 4 else { continue }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let number = (0..<4).reduce(0) { $0 << 8 | Int(buf[$1]) }
            lock.withLock { arrivals.append(Arrival(number: number, bytes: n, atNs: now)) }
        }
    }

    var received: [Arrival] { lock.withLock { arrivals } }

    /// Sends `count` datagrams of `size` bytes numbered from 0 at `perSecond`, on absolute deadlines (batches when the rate is high).
    @discardableResult
    func hostStreams(count: Int, size: Int, perSecond: Double) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for i in 0..<count {
            let due = start + UInt64(Double(i) / perSecond * 1e9)
            while true {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if now >= due { break }
                if due - now > 1_500_000 { usleep(500) }
            }
            hostSends(i, size: size)
        }
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
    }

    /// How many datagrams the Host socket has waiting (stops after 100 ms of quiet).
    func hostDrain() -> Int {
        var buf = [UInt8](repeating: 0, count: 2048)
        var n = 0
        var quiet = 0
        while quiet < 5 {
            if recv(host, &buf, buf.count, 0) > 0 { n += 1; quiet = 0 } else { quiet += 1 }
        }
        return n
    }

    func settle(_ seconds: Double = 0.4) { Thread.sleep(forTimeInterval: seconds) }

    func close() {
        shaper.stop()
        lock.withLock { running = false }
        reader.wait()
        Foundation.close(client); Foundation.close(host)
    }
}

final class LinkShaperTests: XCTestCase {
    private func rig(_ profile: LinkProfile, seed: UInt64 = 7) throws -> Rig {
        let r = try Rig(profile, seed: seed)
        r.clientSends(0)
        XCTAssertTrue(r.waitHostHears(), "the Host socket heard nothing through the shaper")
        return r
    }

    func testUnknownProfileNameIsNil() {
        XCTAssertNil(LinkProfile.named("nope"))
        for name in LinkProfile.names { XCTAssertNotNil(LinkProfile.named(name), name) }
    }

    func testCleanForwardsEverythingInOrder() throws {
        let r = try rig(.clean)
        defer { r.close() }
        r.hostStreams(count: 2000, size: 200, perSecond: 4000)
        r.settle()
        XCTAssertEqual(r.received.map(\.number), Array(0..<2000))
        XCTAssertEqual(r.shaper.counts.dropped, 0)
        XCTAssertEqual(r.shaper.counts.forwarded, 2000)
    }

    func testLossyDropsAboutOnePercent() throws {
        let r = try rig(.lossy)
        defer { r.close() }
        r.hostStreams(count: 20_000, size: 100, perSecond: 16000)
        r.settle()
        let lost = 20_000 - r.received.count
        XCTAssertTrue((100...300).contains(lost), "lost \(lost) of 20000")
        XCTAssertEqual(lost, r.shaper.counts.dropped)
        let numbers = r.received.map(\.number)
        XCTAssertEqual(numbers, numbers.sorted(), "order kept")
    }

    func testBurstyLossComesInRuns() throws {
        let r = try rig(.bursty)
        defer { r.close() }
        r.hostStreams(count: 20_000, size: 100, perSecond: 16000)
        r.settle()
        let got = Set(r.received.map(\.number))
        var runs: [Int] = []
        var current = 0
        for n in 0..<20_000 {
            if got.contains(n) { if current > 0 { runs.append(current); current = 0 } } else { current += 1 }
        }
        if current > 0 { runs.append(current) }
        XCTAssertFalse(runs.isEmpty, "nothing was lost")
        XCTAssertGreaterThanOrEqual(runs.min() ?? 0, 3, "runs \(runs)")
        XCTAssertLessThanOrEqual(runs.max() ?? 0, 12, "runs \(runs)")
        XCTAssertTrue((20...120).contains(runs.count), "\(runs.count) runs")
    }

    func testStallsHoldThenReleaseAndLoseNothing() throws {
        let r = try rig(.stalls)
        defer { r.close() }
        r.hostStreams(count: 1750, size: 100, perSecond: 500)  // 3.5 s
        r.settle()
        let got = r.received
        XCTAssertEqual(got.map(\.number), Array(0..<1750), "no loss, in order")
        let gaps = zip(got, got.dropFirst()).map { Double($1.atNs - $0.atNs) / 1e6 }.filter { $0 > 40 }
        XCTAssertTrue((2...4).contains(gaps.count), "gaps \(gaps)")
        for g in gaps { XCTAssertTrue((70...100).contains(g), "gap \(g) ms in \(gaps)") }
    }

    func testNarrowDeliversAboutItsRateAndDropsTheRest() throws {
        let r = try rig(.narrow)
        defer { r.close() }
        let count = 15_000
        let seconds = r.hostStreams(count: count, size: 1200, perSecond: 5200)  // ~50 Mbit/s offered
        r.settle()
        let offered = Double(count * 1200) * 8 / seconds / 1e6
        let delivered = Double(r.received.reduce(0) { $0 + $1.bytes }) * 8 / seconds / 1e6
        XCTAssertGreaterThan(offered, 40, "the sender only offered \(offered) Mbit/s")
        XCTAssertTrue((22...27).contains(delivered), "delivered \(delivered) Mbit/s of \(offered) offered")
        XCTAssertGreaterThan(r.shaper.counts.dropped, count / 3)
        XCTAssertEqual(r.shaper.counts.dropped + r.received.count, count)
    }

    func testSameSeedSameDrops() throws {
        func drops(seed: UInt64) throws -> [Int] {
            var p = LinkProfile.bursty
            p.loss = 0.02  // enough drops in 3000 datagrams to compare
            p.delayMs = 0; p.jitterMs = 0
            let r = try rig(p, seed: seed)
            defer { r.close() }
            r.hostStreams(count: 3000, size: 100, perSecond: 6000)
            r.settle()
            let got = Set(r.received.map(\.number))
            return (0..<3000).filter { !got.contains($0) }
        }
        let a = try drops(seed: 42), b = try drops(seed: 42), c = try drops(seed: 43)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testClientToHostSkipsTheBottleneckAndStalls() throws {
        var p = LinkProfile.narrow
        p.stallEveryMs = 200; p.stallMs = 100
        let r = try rig(p)
        defer { r.close() }
        for i in 1...3000 { r.clientSends(i, size: 1200) }  // far above 25 Mbit/s, all at once
        r.settle()
        XCTAssertEqual(r.hostDrain(), 3000)
        XCTAssertEqual(r.shaper.counts.dropped, 0)
    }
}
#endif
