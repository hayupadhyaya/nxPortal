#if os(macOS)
import Foundation

/// What a bad network does to datagrams -> .claude/portalkit.md § test-network
public struct LinkProfile: Sendable, Equatable {
    /// Chance a datagram is lost (`lossRun == 1...1`) or starts a run of lost ones (any other `lossRun`).
    public var loss: Double
    /// Length of a loss run, drawn uniformly; `1...1` = independent loss.
    public var lossRun: ClosedRange<Int>
    /// Each datagram is held `delayMs ± jitterMs` (uniform); order is kept unless `reorder` says otherwise.
    public var delayMs: Double
    public var jitterMs: Double
    /// Chance a datagram skips the order rule and is held a further 10 ms.
    public var reorder: Double
    /// For the last `stallMs` of every `stallEveryMs` (from `start()`) nothing is forwarded; 0 = no stalls.
    public var stallEveryMs: Int
    public var stallMs: Int
    /// Host to client only: a bottleneck of this rate with a tail-drop queue of `queueMs` of it; 0 = none.
    public var rateMbps: Double
    public var queueMs: Int
    /// The `random` profile: a background drawn from the seed, and an endless series of events -> `LinkShaper.events`.
    public var randomEvents = false
    /// A seed the profile carries (`random(seed:)`); it replaces the one given to the shaper. nil = the shaper's.
    public var seed: UInt64?

    public init(loss: Double = 0, lossRun: ClosedRange<Int> = 1...1, delayMs: Double = 0, jitterMs: Double = 0,
                reorder: Double = 0, stallEveryMs: Int = 0, stallMs: Int = 0, rateMbps: Double = 0, queueMs: Int = 0,
                randomEvents: Bool = false, seed: UInt64? = nil) {
        self.randomEvents = randomEvents; self.seed = seed
        self.loss = loss; self.lossRun = lossRun; self.delayMs = delayMs; self.jitterMs = jitterMs
        self.reorder = reorder; self.stallEveryMs = stallEveryMs; self.stallMs = stallMs
        self.rateMbps = rateMbps; self.queueMs = queueMs
    }

    public static let clean = LinkProfile()
    public static let lossy = LinkProfile(loss: 0.01, delayMs: 2, jitterMs: 1)
    public static let bursty = LinkProfile(loss: 0.003, lossRun: 3...12, delayMs: 2, jitterMs: 2)
    public static let stalls = LinkProfile(delayMs: 2, jitterMs: 1, stallEveryMs: 1000, stallMs: 80)
    public static let narrow = LinkProfile(delayMs: 2, jitterMs: 1, rateMbps: 25, queueMs: 30)

    /// Unscripted trouble from one seed: loss drawn once in 0...0.5 %, jitter 1...4 ms, and after every pause of 0.5...3 s
    /// one event of the six in `LinkShaper.EventKind` (or nothing). `nil` seed = the shaper's.
    public static func random(seed: UInt64? = nil) -> LinkProfile { LinkProfile(randomEvents: true, seed: seed) }

    /// The seed a tool runs a named profile with: the one given, else a fresh one for `random` (the tool prints it, so a
    /// bad run can be replayed), else 1 (the scripted profiles are the same every time).
    public static func seed(for name: String, given: UInt64?) -> UInt64 {
        given ?? (name == "random" ? UInt64.random(in: 1...9_999_999) : 1)
    }

    public static let names = ["clean", "lossy", "bursty", "stalls", "narrow", "random"]

    public static func named(_ name: String) -> LinkProfile? {
        switch name {
        case "clean": .clean
        case "lossy": .lossy
        case "bursty": .bursty
        case "stalls": .stalls
        case "narrow": .narrow
        case "random": .random()
        default: nil
        }
    }
}

/// SplitMix64: the shaper's only source of randomness.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A UDP relay on loopback that loses, delays, holds and squeezes whole datagrams, never looking inside them.
/// A client sends to `start()`'s port; the shaper forwards to the Host's media port and sends the Host's datagrams
/// back to the client's address (learned from the latest datagram that came in) -> .claude/portalkit.md § test-network
/// Host to client follows the whole profile; client to Host only its loss and delay. Each direction has its own seeded
/// generator (and the `random` events another, all derived from the one seed), so the same input gives the same drops
/// (with delay and jitter at 0, since real time does not repeat).
public final class LinkShaper: @unchecked Sendable {
    enum Direction { case toClient, toHost }

    /// What the `random` profile did and when (`Event`), drawn from the seed.
    public enum EventKind: Equatable, Sendable {
        /// The next `count` datagrams (5...60), either direction, are lost.
        case loss(count: Int)
        /// Nothing passes for `ms` (20...400), then everything is released, either direction.
        case stall(ms: Double)
        /// Each datagram is held a random 5...`extraMs` ms more (`extraMs` 5...40), for 0.2...2 s, either direction.
        case jitterSpike(extraMs: Double)
        /// Host to client: a bottleneck of `mbps` (20...80 % of the rate the stream had been running at over the last
        /// second or the time it has been running, never under 2 Mbit/s) with a 30 ms queue, for 0.5...3 s.
        case rateDip(mbps: Double)
        /// 10 % of datagrams, either direction, are held 2...8 ms and so overtaken, for 0.5...2 s.
        case reorderSpell

        public var name: String {
            switch self {
            case let .loss(n): "loss\(n)"
            case let .stall(ms): String(format: "stall%.0fms", ms)
            case let .jitterSpike(ms): String(format: "jitter%.0fms", ms)
            case let .rateDip(r): String(format: "dip%.1fmbit", r)
            case .reorderSpell: "reorder"
            }
        }
    }

    /// An event that began: `startNs` / `endNs` on the shaper's clock (`endNs` = `startNs` until it has ended).
    public struct Event: Equatable, Sendable {
        public var kind: EventKind
        public var startNs: UInt64, endNs: UInt64
        public var ended: Bool
    }

    private struct Item { var release: UInt64; var seq: UInt64; var direction: Direction; var data: Data }

    /// One direction's decisions; touched only under `lock`.
    private struct Lane {
        var rng: SplitMix64
        var runLeft = 0
        var lastRelease: UInt64 = 0
        /// Datagrams in the bottleneck: when each leaves it, and its size.
        var queue: [(departNs: UInt64, bytes: Int)] = []
        var queueHead = 0
        var lastDepart: UInt64 = 0
        /// When the next datagram held by `hold(…releaseMbps:)` may leave.
        var holdNext: UInt64 = 0
        init(seed: UInt64) { rng = SplitMix64(seed: seed) }
    }

    /// The seed in use (the profile's own when it carries one). Print it: a bad run is replayed with it.
    public let seed: UInt64
    private let clock: @Sendable () -> UInt64
    private let allInterfaces: Bool
    private let lock = NSCondition()  // guards every var below; the scheduler waits on it
    private var profile: LinkProfile
    /// `random` profile: the generator for the background and the events, when the first Host to client datagram came
    /// (the event clock starts there), the time the next event begins, the one running, what has happened, and when
    /// downstream bytes passed (the rate a dip is a share of).
    private var eventRng: SplitMix64
    private var nextEventNs: UInt64 = 0
    private var firstDownNs: UInt64?
    private var active: Event?
    private var lossLeft = 0
    private var history: [Event] = []
    private var downstream: [(at: UInt64, bytes: Int)] = []
    private var downstreamHead = 0
    private var hostPort: UInt16
    private let hostName: String
    private var lanes: [Lane]
    private var pending: [Item] = []
    private var pendingHead = 0
    private var nextSeq: UInt64 = 0
    private var clientAddress: Data?
    private var hostAddress: Data?
    private var epochNs: UInt64 = 0
    private var running = false
    private var forwarded = 0, dropped = 0, reordered = 0
    private var clientSocket: Int32 = -1  // faces the client
    private var hostSocket: Int32 = -1    // faces the Host
    private let threads = DispatchGroup()

    /// `clock` (ns) is injectable so a test can feed datagrams on a time of its own. `listenOnAllInterfaces`: the
    /// client-facing socket is dual-stack and bound to every interface (a device on the network), not loopback only.
    public init(profile: LinkProfile, seed: UInt64, to host: (String, UInt16), listenOnAllInterfaces: Bool = false,
                clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        let seed = profile.seed ?? seed
        self.seed = seed
        self.clock = clock
        allInterfaces = listenOnAllInterfaces
        var shaped = profile
        eventRng = SplitMix64(seed: seed ^ 0x5EED_E7E4_7500_0001)
        if profile.randomEvents {
            // The background, drawn once: loss 0...0.5 %, jitter 1...4 ms (held that long too).
            shaped.loss = eventRng.unit() * 0.005
            shaped.jitterMs = 1 + eventRng.unit() * 3
            shaped.delayMs = shaped.jitterMs
        }
        self.profile = shaped
        hostName = host.0
        hostPort = host.1
        lanes = [Lane(seed: seed), Lane(seed: seed ^ 0xA5A5_A5A5_5A5A_5A5A)]
        epochNs = clock()
    }

    /// 0.5...3 s.
    private func pause() -> UInt64 { UInt64((0.5 + eventRng.unit() * 2.5) * 1e9) }

    /// Binds both sockets and starts the threads; returns the port a client sends to. The Host-facing socket is
    /// IPv4 on any port (it talks to the Host on loopback); the client-facing one is loopback IPv4, or with
    /// `listenOnAllInterfaces` IPv6 dual-stack on every interface.
    public func start() throws -> UInt16 {
        let host = try Self.makeSocket(AF_INET)
        let client = try Self.makeSocket(allInterfaces ? AF_INET6 : AF_INET)
        var port: UInt16 = 0
        if allInterfaces {
            var off: Int32 = 0
            setsockopt(client, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_any
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(client, $0, len) == 0 && getsockname(client, $0, &len) == 0 }
            }
            guard bound else { let e = errno; close(client); close(host); throw LinkShaperError.system("bind", e) }
            port = UInt16(bigEndian: addr.sin6_port)
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(client, $0, len) == 0 && getsockname(client, $0, &len) == 0 }
            }
            guard bound else { let e = errno; close(client); close(host); throw LinkShaperError.system("bind", e) }
            port = UInt16(bigEndian: addr.sin_port)
        }
        lock.lock()
        clientSocket = client; hostSocket = host
        let began = clock()
        epochNs = began
        running = true
        lock.unlock()
        threads.enter(); Thread.detachNewThread { self.receive(client, from: .toHost); self.threads.leave() }
        threads.enter(); Thread.detachNewThread { self.receive(host, from: .toClient); self.threads.leave() }
        threads.enter(); Thread.detachNewThread { self.schedule(); self.threads.leave() }
        return port
    }

    /// Idempotent; waits for the threads.
    public func stop() {
        lock.lock()
        let was = running
        running = false
        lock.broadcast()
        lock.unlock()
        guard was else { return }
        threads.wait()
        lock.lock()
        close(clientSocket); close(hostSocket)
        clientSocket = -1; hostSocket = -1
        lock.unlock()
    }

    /// What the `random` profile did so far, in order (empty for any other profile); `ended` is false for one still running.
    public var events: [Event] { lock.lock(); defer { lock.unlock() }; return history }

    /// Release times of what is queued (tests).
    var pendingReleases: [UInt64] { lock.lock(); defer { lock.unlock() }; return pending[pendingHead...].map(\.release) }

    /// The profile in use (for `random`, with the background drawn from the seed).
    public var profileInUse: LinkProfile { lock.lock(); defer { lock.unlock() }; return profile }

    /// The shaper's clock, in ns (what `Event` times are on).
    public var nowNs: UInt64 { clock() }

    /// Takes effect from the next datagram; the stall clock keeps running.
    public func setProfile(_ profile: LinkProfile) { lock.lock(); self.profile = profile; lock.unlock() }

    /// Holds everything for `ms` from now, then releases it all at once (a radio that stalls and then delivers what it
    /// kept), or at `releaseMbps` (a radio delivering its backlog at its own rate; 0 = at once); `towardClientOnly` holds
    /// only the Host to client direction. The profile's own loss and delay still apply.
    public func hold(forMs ms: Double, towardClientOnly: Bool = false, releaseMbps: Double = 0) {
        lock.lock()
        holdUntilNs = clock() &+ UInt64(ms * 1e6)
        holdTowardClientOnly = towardClientOnly
        holdReleaseMbps = releaseMbps
        lock.unlock()
    }

    /// For a Host whose media port is learned after the shaper exists (the `welcome`).
    public func setHostPort(_ port: UInt16) { lock.lock(); hostPort = port; hostAddress = nil; lock.unlock() }

    /// Host to client only: what the shaper let through, lost (loss and tail drop), and held back out of order.
    public var counts: (forwarded: Int, dropped: Int, reordered: Int) {
        lock.lock(); defer { lock.unlock() }
        return (forwarded, dropped, reordered)
    }

    // MARK: sockets

    private func now() -> UInt64 { clock() }

    private static func makeSocket(_ family: Int32) throws -> Int32 {
        let s = socket(family, SOCK_DGRAM, 0)
        guard s >= 0 else { throw LinkShaperError.system("socket", errno) }
        var size: Int32 = 8 << 20
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, intSize)
        setsockopt(s, SOL_SOCKET, SO_SNDBUF, &size, intSize)
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)  // so `stop()` is noticed
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return s
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func receive(_ s: Int32, from direction: Direction) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while isRunning() {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            let at = now()
            let data = Data(buffer[0..<n])
            lock.lock()
            if direction == .toHost {  // came from the client
                clientAddress = withUnsafeBytes(of: &from) { Data($0.prefix(Int(fromLen))) }
            }
            admit(data, direction: direction, at: at)
            lock.unlock()
        }
    }

    // MARK: shaping (under `lock`)

    /// Where `t` falls in a stall, the time the stall ends; else `t`.
    private func afterStall(_ t: UInt64) -> UInt64 {
        guard profile.stallEveryMs > 0, profile.stallMs > 0 else { return t }
        let every = UInt64(profile.stallEveryMs) * 1_000_000, stall = UInt64(profile.stallMs) * 1_000_000
        guard t >= epochNs else { return t }
        let phase = (t - epochNs) % every
        return phase >= every - stall ? t + (every - phase) : t
    }

    private var holdUntilNs: UInt64 = 0
    private var holdTowardClientOnly = false
    private var holdReleaseMbps = 0.0

    /// What an event changes for one datagram.
    private struct Effects {
        var stallEnd: UInt64 = 0
        var extraJitterMs = 0.0
        var reorderHoldMs: ClosedRange<Double>?
        var dropForEvent = false
    }

    /// Under `lock`. The events begin and end on the clock of the datagrams that pass, in the order the seed drew them,
    /// so the same seed and the same traffic make the same run.
    private func advanceEvents(to t: UInt64) {
        guard profile.randomEvents, firstDownNs != nil else { return }
        while true {
            if let a = active, t >= a.endNs { finishActive(at: a.endNs) }
            guard active == nil else { return }
            // Never replay events across an idle gap (nobody was sending): the next one is a pause from now.
            if t > nextEventNs &+ 3_000_000_000 { nextEventNs = t &+ pause() }
            guard t >= nextEventNs else { return }
            begin(at: nextEventNs)
        }
    }

    private func finishActive(at end: UInt64) {
        guard var a = active else { return }
        a.endNs = end; a.ended = true
        history[history.count - 1] = a
        active = nil
        lossLeft = 0
        nextEventNs = end + pause()
    }

    private func begin(at start: UInt64) {
        let ns = { (s: Double) in UInt64(s * 1e9) }
        let kind: EventKind, length: UInt64
        switch eventRng.next() % 6 {
        case 0:
            let n = 5 + Int(eventRng.next() % 56)
            kind = .loss(count: n); length = ns(2)  // ends when its datagrams are gone, or after 2 s
            lossLeft = n
        case 1:
            let ms = 20 + eventRng.unit() * 380
            kind = .stall(ms: ms); length = ns(ms / 1000)
        case 2:
            let extra = 5 + eventRng.unit() * 35
            kind = .jitterSpike(extraMs: extra); length = ns(0.2 + eventRng.unit() * 1.8)
        case 3:
            let share = 0.2 + eventRng.unit() * 0.6
            let len = ns(0.5 + eventRng.unit() * 2.5)
            // A dip is a share of what the stream has been running at: not before half a second of it is known.
            guard let rate = runningMbps(at: start) else { nextEventNs = start + pause(); return }  // nothing this time
            kind = .rateDip(mbps: max(2, rate * share)); length = len
        case 4:
            kind = .reorderSpell; length = ns(0.5 + eventRng.unit() * 1.5)
        default:
            nextEventNs = start + pause()  // nothing this time
            return
        }
        let e = Event(kind: kind, startNs: start, endNs: start + length, ended: false)
        active = e
        history.append(e)
    }

    /// Mbit/s of Host to client traffic over the second before `t` (or since the first one, when younger); nil while
    /// under half a second of it is known.
    private func runningMbps(at t: UInt64) -> Double? {
        guard let first = firstDownNs, t > first, t - first >= 500_000_000 else { return nil }
        var bytes = 0
        for i in downstreamHead..<downstream.count where downstream[i].at <= t && t - downstream[i].at <= 1_000_000_000 {
            bytes += downstream[i].bytes
        }
        return Double(bytes) * 8 / 1e6 / (Double(min(t - first, 1_000_000_000)) / 1e9)
    }

    private func noteDownstream(_ bytes: Int, at t: UInt64) {
        guard profile.randomEvents else { return }
        if firstDownNs == nil { firstDownNs = t; nextEventNs = t &+ pause() }  // the event clock starts with the traffic
        downstream.append((t, bytes))
        while downstreamHead < downstream.count, t &- downstream[downstreamHead].at > 1_000_000_000 { downstreamHead += 1 }
        if downstreamHead > 4096 { downstream.removeFirst(downstreamHead); downstreamHead = 0 }
    }

    /// The datagram is lost to the running loss event: counts it down, and ends the event with its last one.
    private func eventLoses(at t: UInt64) -> Bool {
        guard let a = active, case .loss = a.kind, lossLeft > 0 else { return false }
        lossLeft -= 1
        if lossLeft == 0 { finishActive(at: t) }
        return true
    }

    /// Verdict and queueing of one datagram; false = lost. Under `lock`.
    @discardableResult
    func admit(_ data: Data, direction: Direction, at t: UInt64) -> Bool {
        let lane = direction == .toClient ? 0 : 1
        let down = direction == .toClient
        advanceEvents(to: t)
        var p = profile
        var fx = Effects()
        if let a = active {
            switch a.kind {
            case .loss: break
            case .stall: fx.stallEnd = a.endNs
            case let .jitterSpike(extra): fx.extraJitterMs = extra
            case let .rateDip(mbps): if down { p.rateMbps = mbps; p.queueMs = 30 }
            case .reorderSpell: p.reorder = 0.1; fx.reorderHoldMs = 2...8
            }
        }
        if holdUntilNs > t, down || !holdTowardClientOnly {
            var end = holdUntilNs
            if holdReleaseMbps > 0 {  // the backlog leaves in arrival order at the release rate
                end = max(end, lanes[lane].holdNext)
                lanes[lane].holdNext = end + UInt64(Double(data.count) * 8 / (holdReleaseMbps * 1e6) * 1e9)
            }
            fx.stallEnd = max(fx.stallEnd, end)
        }
        if down { noteDownstream(data.count, at: t) }
        if eventLoses(at: t) { lose(down); return false }
        // loss: independent, or the start of a run
        if lanes[lane].runLeft > 0 {
            lanes[lane].runLeft -= 1
            lose(down); return false
        }
        if p.loss > 0, lanes[lane].rng.unit() < p.loss {
            let run = p.lossRun
            let length = run.lowerBound + Int(lanes[lane].rng.next() % UInt64(run.upperBound - run.lowerBound + 1))
            lanes[lane].runLeft = length - 1
            lose(down); return false
        }
        // bottleneck and stall
        var depart = t
        if fx.stallEnd > t { depart = fx.stallEnd }
        if down {
            depart = afterStall(depart)
            if p.rateMbps > 0 {
                let cap = Int(p.rateMbps * 1e6 / 8 * Double(p.queueMs) / 1000)
                while lanes[lane].queueHead < lanes[lane].queue.count, lanes[lane].queue[lanes[lane].queueHead].departNs <= t {
                    lanes[lane].queueHead += 1
                }
                if lanes[lane].queueHead > 4096 {
                    lanes[lane].queue.removeFirst(lanes[lane].queueHead); lanes[lane].queueHead = 0
                }
                var held = 0
                for i in lanes[lane].queueHead..<lanes[lane].queue.count { held += lanes[lane].queue[i].bytes }
                if held + data.count > cap { lose(down); return false }
                let start = afterStall(max(depart, lanes[lane].lastDepart))
                depart = start + UInt64(Double(data.count) * 8 / (p.rateMbps * 1e6) * 1e9)
                lanes[lane].lastDepart = depart
                lanes[lane].queue.append((depart, data.count))
            }
        }
        // delay, jitter, order
        var jitter = p.jitterMs > 0 ? (lanes[lane].rng.unit() * 2 - 1) * p.jitterMs : 0
        if fx.extraJitterMs > 0 { jitter += 5 + (fx.extraJitterMs - 5) * lanes[lane].rng.unit() }
        var release = depart + UInt64(max(0, p.delayMs + jitter) * 1e6)
        if p.reorder > 0, lanes[lane].rng.unit() < p.reorder {
            let hold = fx.reorderHoldMs.map { $0.lowerBound + lanes[lane].rng.unit() * ($0.upperBound - $0.lowerBound) } ?? 10
            release += UInt64(hold * 1e6)
            if down { reordered += 1 }
        } else {
            release = max(release, lanes[lane].lastRelease)
            lanes[lane].lastRelease = release
        }
        if down { release = afterStall(release) }
        insert(Item(release: release, seq: nextSeq, direction: direction, data: data))
        nextSeq += 1
        lock.broadcast()
        return true
    }

    private func lose(_ down: Bool) { if down { dropped += 1 } }

    /// Sorted by release time, then arrival; datagrams mostly land at the end.
    private func insert(_ item: Item) {
        var i = pending.count
        while i > pendingHead, pending[i - 1].release > item.release { i -= 1 }
        pending.insert(item, at: i)
    }

    // MARK: sending

    private func schedule() {
        lock.lock()
        while running {
            guard pendingHead < pending.count else { lock.wait(until: Date().addingTimeInterval(0.05)); continue }
            let now = self.now()
            var due: [Item] = []
            while pendingHead < pending.count, pending[pendingHead].release <= now {
                due.append(pending[pendingHead]); pendingHead += 1
            }
            if pendingHead > 1024 { pending.removeFirst(pendingHead); pendingHead = 0 }
            if due.isEmpty {
                let wait = Double(pending[pendingHead].release - now) / 1e9
                lock.wait(until: Date().addingTimeInterval(min(wait, 0.05)))
                continue
            }
            let client = clientAddress, host = hostAddress ?? resolveHost()
            let cs = clientSocket, hs = hostSocket
            lock.unlock()
            var passedOn = 0
            for item in due {
                switch item.direction {
                case .toClient: if let client { Self.send(item.data, on: cs, to: client); passedOn += 1 }
                case .toHost: if let host { Self.send(item.data, on: hs, to: host) }
                }
            }
            lock.lock()
            forwarded += passedOn
        }
        lock.unlock()
    }

    /// Under `lock`.
    private func resolveHost() -> Data? {
        guard hostPort != 0 else { return nil }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = hostPort.bigEndian
        guard inet_pton(AF_INET, hostName, &a.sin_addr) == 1 else { return nil }
        let d = withUnsafeBytes(of: &a) { Data($0) }
        hostAddress = d
        return d
    }

    private static func send(_ data: Data, on s: Int32, to address: Data) {
        address.withUnsafeBytes { a in
            data.withUnsafeBytes { d in
                _ = sendto(s, d.baseAddress, d.count, 0, a.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(a.count))
            }
        }
    }
}

public enum LinkShaperError: Error, Equatable { case system(String, Int32) }
#endif
