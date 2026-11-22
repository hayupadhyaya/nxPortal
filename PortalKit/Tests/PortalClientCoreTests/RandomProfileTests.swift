#if os(macOS)
import XCTest
import Foundation
@testable import PortalTestSupport

/// The `random` profile, driven by a clock of the test's own -> .claude/portalkit.md § test-network
final class RandomProfileTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {  // lock-guarded
        private let lock = NSLock()
        private var t: UInt64
        init(_ start: UInt64) { t = start }
        func set(_ v: UInt64) { lock.lock(); t = v; lock.unlock() }
        func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return t }
    }

    private let ms: UInt64 = 1_000_000, sec: UInt64 = 1_000_000_000
    private let origin: UInt64 = 1_000_000_000_000

    private func shaper(seed: UInt64, _ clock: FakeClock, profile: LinkProfile = .random()) -> LinkShaper {
        LinkShaper(profile: profile, seed: seed, to: ("127.0.0.1", 0), clock: { clock.now() })
    }

    /// One datagram a millisecond Host to client (1000 bytes = 8 Mbit/s), every eighth also one the other way, for
    /// `seconds`; `each` sees every datagram's time and verdict, both directions. Returns what was lost (index of the datagram) and, for each, the time it entered.
    @discardableResult
    private func feed(_ s: LinkShaper, _ clock: FakeClock, seconds: Int, from start: UInt64? = nil,
                      each: (UInt64, Bool) -> Void = { _, _ in }) -> (lost: [Int], at: [UInt64]) {
        var lost: [Int] = [], at: [UInt64] = []
        let begin = start ?? origin
        for i in 0..<(seconds * 1000) {
            let t = begin + UInt64(i) * ms
            clock.set(t)
            var kept = s.admit(Data(repeating: UInt8(truncatingIfNeeded: i), count: 1000), direction: .toClient, at: t)
            if !kept { lost.append(i * 2) }
            each(t, kept)
            if i % 8 == 0 {
                kept = s.admit(Data(repeating: 1, count: 80), direction: .toHost, at: t)
                if !kept { lost.append(i * 2 + 1) }
                each(t, kept)
            }
            at.append(t)
        }
        return (lost, at)
    }

    func testRandomIsAProfileName() {
        XCTAssertTrue(LinkProfile.names.contains("random"))
        XCTAssertEqual(LinkProfile.named("random")?.randomEvents, true)
        XCTAssertNil(LinkProfile.named("random")?.seed, "no seed of its own: the shaper's, or a fresh one")
        XCTAssertEqual(LinkProfile.random(seed: 9).seed, 9)
    }

    /// Two shapers, one seed, the same datagrams on the same clock: the same ones lost, the same events.
    func testTheSameSeedAndTrafficMakeTheSameRun() {
        let c1 = FakeClock(origin), c2 = FakeClock(origin), c3 = FakeClock(origin)
        let a = shaper(seed: 42, c1), b = shaper(seed: 42, c2), other = shaper(seed: 43, c3)
        let ra = feed(a, c1, seconds: 60), rb = feed(b, c2, seconds: 60), ro = feed(other, c3, seconds: 60)
        XCTAssertFalse(ra.lost.isEmpty, "a minute of random trouble lost nothing")
        XCTAssertEqual(ra.lost, rb.lost)
        XCTAssertEqual(a.events, b.events)
        XCTAssertFalse(a.events.isEmpty)
        XCTAssertEqual(a.pendingReleases, b.pendingReleases)
        XCTAssertNotEqual(ra.lost, ro.lost, "another seed gave the same run")
        XCTAssertNotEqual(a.events, other.events)
    }

    func testTheSeedInTheProfileIsTheSeedInUse() {
        let c = FakeClock(origin)
        let s = LinkShaper(profile: .random(seed: 77), seed: 5, to: ("127.0.0.1", 0), clock: { c.now() })
        XCTAssertEqual(s.seed, 77)
        XCTAssertEqual(LinkShaper(profile: .random(), seed: 5, to: ("127.0.0.1", 0), clock: { c.now() }).seed, 5)
    }

    func testBackgroundAndEventsStayInTheirRanges() {
        var kinds = Set<String>()
        for seed in UInt64(1)...4 {
            let c = FakeClock(origin)
            let s = shaper(seed: seed, c)
            let bg = s.profileInUse
            XCTAssertTrue((0...0.005).contains(bg.loss), "background loss \(bg.loss)")
            XCTAssertTrue((1...4).contains(bg.jitterMs), "background jitter \(bg.jitterMs)")
            feed(s, c, seconds: 150)
            let events = s.events
            XCTAssertGreaterThan(events.count, 30)
            var previousEnd = origin
            for e in events {
                let pause = Double(e.startNs - previousEnd) / 1e9
                // A pause is 0.5...3 s; an event drawn as "nothing" lets the next pause follow at once.
                XCTAssertTrue((0.5...12).contains(pause), "pause before \(e.kind.name): \(pause) s")
                let length = Double(e.endNs - e.startNs) / 1e9
                switch e.kind {
                case let .loss(n): XCTAssertTrue((5...60).contains(n), "\(n)"); kinds.insert("loss")
                case let .stall(ms):
                    XCTAssertTrue((20...400).contains(ms), "\(ms)")
                    XCTAssertEqual(length * 1000, ms, accuracy: 1)
                    kinds.insert("stall")
                case let .jitterSpike(extra):
                    XCTAssertTrue((5...40).contains(extra), "\(extra)")
                    XCTAssertTrue((0.2...2.001).contains(length), "\(length)")
                    kinds.insert("jitter")
                case let .rateDip(mbps):
                    XCTAssertTrue((2...6.4 * 1.1).contains(mbps), "a dip to \(mbps) Mbit/s of an 8 Mbit/s stream (2 Mbit/s at least)")
                    XCTAssertTrue((0.5...3.001).contains(length), "\(length)")
                    kinds.insert("dip")
                case .reorderSpell:
                    XCTAssertTrue((0.5...2.001).contains(length), "\(length)")
                    kinds.insert("reorder")
                }
                previousEnd = e.endNs
            }
        }
        XCTAssertEqual(kinds, ["loss", "stall", "jitter", "dip", "reorder"])
    }

    /// The pause clock starts with the first Host to client datagram, not with the shaper: 20 s of client to Host
    /// datagrams make no event, and the first one comes 0.5...3 s after the first downstream datagram.
    func testTheEventClockStartsWithTheTraffic() {
        for seed in UInt64(1)...6 {
            let c = FakeClock(origin)
            let s = shaper(seed: seed, c)
            for i in 0..<20_000 {
                let t = origin + UInt64(i) * ms
                clock(c, t)
                s.admit(Data(count: 80), direction: .toHost, at: t)
            }
            XCTAssertTrue(s.events.isEmpty, "events before any traffic from the Host")
            let first = origin + 20 * sec
            feed(s, c, seconds: 6, from: first)
            let e = s.events.first
            XCTAssertNotNil(e, "no event in 6 s of traffic, seed \(seed)")
            if let e { XCTAssertGreaterThanOrEqual(e.startNs, first + 500 * ms, "seed \(seed): an event began \(Double(e.startNs - first) / 1e6) ms into the traffic") }
        }
    }

    private func clock(_ c: FakeClock, _ t: UInt64) { c.set(t) }

    /// Nothing replays across an idle gap: after a minute of silence the next event is a pause from the new traffic.
    func testNoEventsAreReplayedAcrossAnIdleGap() {
        let c = FakeClock(origin)
        let s = shaper(seed: 11, c)
        feed(s, c, seconds: 10)
        let before = s.events.count
        let resume = origin + 70 * sec
        feed(s, c, seconds: 5, from: resume)
        let gap = s.events.filter { $0.startNs > origin + 11 * sec && $0.startNs < resume }
        XCTAssertTrue(gap.isEmpty, "\(gap.count) events began inside the silence")
        for e in s.events.dropFirst(before) { XCTAssertGreaterThanOrEqual(e.startNs, resume + 500 * ms) }
    }

    /// A dip is a share of the traffic actually seen: a 1 Mbit/s stream is never cut below 2 Mbit/s, and a dip is not
    /// drawn before half a second of traffic is known.
    func testADipIsAShareOfTheTrafficSeenWithAFloor() {
        var dips = 0
        for seed in UInt64(1)...12 {
            let c = FakeClock(origin)
            let s = shaper(seed: seed, c)
            for i in 0..<60_000 {  // 60 s at 125 datagrams a second of 1000 bytes = 1 Mbit/s
                let t = origin + UInt64(i) * 8 * ms
                c.set(t)
                s.admit(Data(count: 1000), direction: .toClient, at: t)
            }
            for e in s.events { if case let .rateDip(m) = e.kind { dips += 1; XCTAssertGreaterThanOrEqual(m, 2, "a dip to \(m) Mbit/s") } }
        }
        XCTAssertGreaterThan(dips, 5)
    }

    /// A jitter spike holds each datagram 5...extraMs more (extraMs 5...40), no more, no less. Nothing else delays
    /// (no background), so: nothing leaves in the 5 ms after the spike begins, and everything that entered from its
    /// start to `extraMs` after its end has left by then.
    func testAJitterSpikeHoldsDatagramsBetweenFiveMsAndItsExtra() {
        var spikes = 0
        for seed in UInt64(1)...8 {
            let c = FakeClock(origin)
            let s = shaper(seed: seed, c, profile: LinkProfile(randomEvents: true))
            s.setProfile(LinkProfile(randomEvents: true))
            let fed = feed(s, c, seconds: 100)
            let releases = s.pendingReleases
            let events = s.events
            for (n, e) in events.enumerated() { if case let .jitterSpike(extra) = e.kind {
                // No other event within 40 ms of this one's end (the next pause is 0.5 s at least: always true) and none overlapping.
                _ = n
                spikes += 1
                let inFirst5 = releases.filter { $0 > e.startNs && $0 < e.startNs + 5 * ms }
                XCTAssertTrue(inFirst5.isEmpty, "seed \(seed): \(inFirst5.count) datagrams of the spike left in under 5 ms")
                let limit = e.endNs + UInt64(extra * 1e6)
                var entered = 0
                for (i, t) in fed.at.enumerated() where t >= e.startNs && t <= limit { entered += 1 + (i % 8 == 0 ? 1 : 0) }
                let left = releases.filter { $0 > e.startNs && $0 <= limit }.count
                XCTAssertEqual(left, entered, "seed \(seed): spike of \(extra) ms: \(entered - left) datagrams were held past its extra")
            } }
        }
        XCTAssertGreaterThan(spikes, 3)
    }

    func testAStallHoldsEverythingAndReleasesItAtItsEnd() {
        let c = FakeClock(origin)
        let s = shaper(seed: 3, c)
        let seen = Seen()
        feed(s, c, seconds: 120) { t, kept in seen.add(t, kept) }
        let stalls = s.events.filter { if case .stall = $0.kind { true } else { false } }
        XCTAssertFalse(stalls.isEmpty)
        // Releases: every datagram that entered inside a stall is released at or after its end.
        let releases = s.pendingReleases
        XCTAssertGreaterThan(releases.count, 100_000)
        for e in stalls {
            // What entered before the stall may still leave in its first 10 ms (delay and jitter up to 8 ms in flight).
            let held = releases.filter { $0 >= e.startNs + 10 * ms && $0 < e.endNs }
            XCTAssertTrue(held.isEmpty, "something left during a stall: \(held.count)")
            let atEnd = releases.filter { $0 >= e.endNs && $0 < e.endNs + 10 * ms }.count
            XCTAssertGreaterThan(atEnd, Int(e.endNs - e.startNs) / Int(ms), "what was held is released together at the end")
        }
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(UInt64, Bool)] = []
        func add(_ t: UInt64, _ k: Bool) { lock.lock(); list.append((t, k)); lock.unlock() }
        var all: [(UInt64, Bool)] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func testALossRunLosesItsCountOfDatagrams() {
        let c = FakeClock(origin)
        let s = shaper(seed: 5, c, profile: LinkProfile(randomEvents: true))
        s.setProfile(LinkProfile(randomEvents: true))  // no background loss: only the events lose
        let seen = Seen()
        feed(s, c, seconds: 120) { t, kept in seen.add(t, kept) }
        let runs = s.events.compactMap { e -> (LinkShaper.Event, Int)? in if case let .loss(n) = e.kind { (e, n) } else { nil } }
        XCTAssertFalse(runs.isEmpty)
        let down = seen.all
        for (e, n) in runs {
            let lostIn = down.filter { $0.0 >= e.startNs && $0.0 <= e.endNs && !$0.1 }.count
            XCTAssertEqual(lostIn, n, "a run of \(n) lost \(lostIn)")
            XCTAssertEqual(e.ended, true)
            XCTAssertGreaterThan(lostIn, 0)
        }
    }

    func testEveryInterfaceCanReachTheClientSocket() throws {
        // A datagram sent to this Mac's own network address (not loopback) must reach a shaper that listens on all.
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { throw XCTSkip("no interface list") }
        defer { freeifaddrs(ifaddr) }
        var lan: sockaddr_in?
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET), i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               i.pointee.ifa_flags & UInt32(IFF_UP) != 0 {
                lan = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                break
            }
            p = i.pointee.ifa_next
        }
        guard var target = lan else { throw XCTSkip("no network address up besides loopback") }

        let host = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(host) }
        var ha = sockaddr_in()
        ha.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); ha.sin_family = sa_family_t(AF_INET)
        ha.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &ha) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(host, $0, len); return getsockname(host, $0, &len) } }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(host, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let shaper = LinkShaper(profile: .clean, seed: 1, to: ("127.0.0.1", UInt16(bigEndian: ha.sin_port)), listenOnAllInterfaces: true)
        let port = try shaper.start()
        defer { shaper.stop() }
        target.sin_port = port.bigEndian
        let client = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(client) }
        let payload: [UInt8] = [1, 2, 3, 4]
        let sent = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(client, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(sent, 4)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = recv(host, &buf, buf.count, 0)
        XCTAssertEqual(n, 4, "a datagram to the network address did not reach the Host side")
    }
}
#endif
