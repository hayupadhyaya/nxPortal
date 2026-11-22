#if os(macOS)
import Foundation
import os
import PortalKit

/// What a socket did with one datagram.
enum TransmitOutcome: Sendable {
    case sent
    /// The buffer or the interface queue is full: the datagram stays where it is and is tried again at the next slice.
    case wouldBlock
    /// Lost for a reason that will not pass (counted by the socket).
    case failed
}

/// The sender's socket; a recording one stands in for it in the tests.
protocol MediaTransmitting: Sendable {
    func transmit(_ sealed: Data, to address: UDPAddress) -> TransmitOutcome
}

/// The sender's queues and its schedule, without a thread or a clock of its own (time is an argument), so the pacing
/// is testable to the nanosecond -> .claude/host.md § sender
///
/// Three queues, served in this order: `urgent` (pong, sound, `hostStats`, control replies) leaves at once, never
/// waiting for a slice; `resend` leaves at most `resendsPerSlice` per 1 ms slice; `video` frames are released in
/// slices of 1 ms so that the last one leaves `window` after the first. A late wake-up sends the slices that are due
/// (the schedule never shifts). Behind them one `lazy` slot (the Mac's load): the newest replaces the one waiting, and it
/// leaves only when no resend or video waits, so it never goes ahead of either; a socket that refuses it keeps it for the
/// next slice, a newer one replaces it, it is never retransmitted.
struct PacingQueues {
    static let sliceNs: UInt64 = 1_000_000
    /// A frame of this many datagrams or fewer leaves at once.
    static let smallFrame = 8
    static let resendsPerSlice = 32
    /// At most this many slices of credit are given for a late wake-up (a resend burst after a stall stays bounded).
    static let maxCatchUpSlices = 4
    static let maxBacklogNs: UInt64 = 100_000_000
    /// Urgent datagrams kept while the socket refuses them (about a second of sound).
    static let maxUrgent = 256

    struct Counts: Equatable, Sendable {
        /// Frames whose last datagram has left.
        var framesSent = 0
        /// Frames dropped unsent (backlog).
        var framesDropped = 0
        /// Resend datagrams that have left.
        var resent = 0
    }

    private struct QueuedFrame {
        let fragments: [VideoFragment]
        /// Slices it is spread over (1 = at once).
        let slices: Int
        var key: Bool { fragments[0].key }
        /// A key or repair frame: the client restarts its picture there, so the backlog never drops it.
        var restart: Bool { fragments[0].key || fragments[0].repair }
        /// The slice it begins at; nil until it reaches the head of the queue.
        var startSlice: Int?
        var sent = 0
        var number: UInt32 { fragments[0].frame }
        /// Time still to spend on it.
        var remainingNs: UInt64 {
            // A small frame still takes its slice: frames queued behind a blocked socket count towards the backlog.
            guard slices > 1 else { return PacingQueues.sliceNs }
            return UInt64(slices) * PacingQueues.sliceNs * UInt64(fragments.count - sent) / UInt64(fragments.count)
        }
    }

    /// 0 = everything at once.
    let paceNs: UInt64
    /// No frame leaves faster than this multiple of the video rate.
    let pacePeak: Double
    private var urgent: [Datagram] = [], urgentHead = 0
    private var lazy: Datagram?
    private var resend: [VideoFragment] = [], resendHead = 0
    private var video: [QueuedFrame] = [], videoHead = 0
    /// Slice `i` is due at `trainStartNs + i x sliceNs`; nil while only urgent datagrams (or nothing) are queued.
    private var trainStartNs: UInt64?
    /// The newest slice served.
    private var served = -1
    /// The slice after the newest frame's last one: where the next frame begins.
    private var nextFrameSlice = 0
    private(set) var counts = Counts()
    /// The datagram at the head of each queue, sealed, kept while the socket refuses it (sealed once, never again).
    private var urgentCache: Data?, resendCache: Data?, videoCache: Data?
    /// While the socket refuses an urgent datagram nothing is retried before this time (one slice later).
    private var blockedUntilNs: UInt64 = 0

    /// How late each slice left against its schedule (`trainStartNs + slice x 1 ms`; the first slice of a train is due
    /// when the work was enqueued, so the wake-up hop counts): 50 us buckets up to 20 ms, then one for the rest.
    struct Lateness: Equatable, Sendable {
        static let bucketUs = 50, buckets = 401
        var slices = 0
        var histogram = [Int](repeating: 0, count: Lateness.buckets)
        var maxUs = 0
        /// The worst since `takeWindowMax()` (hostStats asks once a second).
        var windowMaxUs = 0

        mutating func record(_ ns: UInt64) {
            let us = Int(min(ns / 1000, 3_600_000_000))
            slices += 1
            histogram[min(us / Self.bucketUs, Self.buckets - 1)] += 1
            maxUs = max(maxUs, us)
            windowMaxUs = max(windowMaxUs, us)
        }

        /// The 95th percentile in us (the top of its bucket).
        var p95Us: Int {
            guard slices > 0 else { return 0 }
            let want = (slices * 95 + 99) / 100
            var seen = 0
            for (i, n) in histogram.enumerated() {
                seen += n
                if seen >= want { return i == Self.buckets - 1 ? maxUs : (i + 1) * Self.bucketUs }
            }
            return maxUs
        }
    }
    private(set) var lateness = Lateness()

    /// The worst lateness (us) since the last call.
    mutating func takeWindowMaxUs() -> Int { defer { lateness.windowMaxUs = 0 }; return lateness.windowMaxUs }

    init(paceNs: UInt64, pacePeak: Double = 3) { self.paceNs = min(paceNs, 1_000_000_000); self.pacePeak = min(max(1, pacePeak), 20) }

    var isEmpty: Bool { urgentHead == urgent.count && resendHead == resend.count && videoHead == video.count }
    var hasPaced: Bool { resendHead < resend.count || videoHead < video.count }

    /// An urgent datagram leaves now when nothing urgent waits and the socket took the last one; else it queues
    /// (the caller wakes the sender). `emit` as for `drain`.
    mutating func sendUrgent(_ d: Datagram, nowNs: UInt64, emit: (Datagram, inout Data?) -> TransmitOutcome) {
        if urgentHead == urgent.count, nowNs >= blockedUntilNs {
            var cache: Data?
            if emit(d, &cache) == .wouldBlock {
                queueUrgent(d)
                urgentCache = cache
                blockedUntilNs = nowNs + Self.sliceNs
            }
            return
        }
        queueUrgent(d)
    }

    /// While the socket refuses everything (the client unreachable, the interface queue full) only the newest
    /// `maxUrgent` urgent datagrams wait: older sound and statistics are stale by the time the socket takes them.
    private mutating func queueUrgent(_ d: Datagram) {
        if urgent.count - urgentHead >= Self.maxUrgent {
            urgentHead += 1
            urgentCache = nil  // it belonged to the head that went
            if urgentHead > Self.maxUrgent { urgent.removeFirst(urgentHead); urgentHead = 0 }
        }
        urgent.append(d)
    }

    var hasUrgent: Bool { urgentHead < urgent.count }

    /// The newest lazy datagram waits here until the paced queues are empty.
    mutating func setLazy(_ d: Datagram) { lazy = d }
    var hasLazy: Bool { lazy != nil }

    /// Datagrams and frames waiting (tests; the Host's numbers are `counts`).
    var urgentQueued: Int { urgent.count - urgentHead }
    var framesQueued: Int { video.count - videoHead }

    mutating func enqueueResend(_ f: VideoFragment, nowNs: UInt64) {
        startTrain(nowNs)
        resend.append(f)
    }

    /// The slices a frame is spread over: its window is `max(paceMs, bytes / (pacePeak x the video rate))`, not capped
    /// at the frame period: no frame leaves faster than `pacePeak` times the rate the encoder was told, so a large one
    /// takes longer and the frames behind it wait. A frame of `smallFrame` datagrams or fewer, or any frame at `paceMs` 0,
    /// leaves at once.
    func slices(frameBytes: Int, count: Int, bytesPerSecond: Double) -> Int {
        guard paceNs > 0, count > Self.smallFrame else { return 1 }
        let peak = bytesPerSecond > 0 ? Double(frameBytes) / (pacePeak * bytesPerSecond) * 1e9 : 0
        let window = max(Double(paceNs), peak)
        return Int((window / Double(Self.sliceNs)).rounded(.up)) + 1
    }

    /// Queues a frame; a key frame drops the frames before it that have not begun; more than 100 ms of sending queued behind
    /// the frame now leaving drops the oldest frame not begun, whole, never a key or repair frame.
    /// Returns the numbers of the frames dropped (the caller forgets them everywhere else too).
    mutating func enqueueFrame(_ fragments: [VideoFragment], nowNs: UInt64, bytesPerSecond: Double) -> [UInt32] {
        guard !fragments.isEmpty else { return [] }
        startTrain(nowNs)
        let bytes = fragments.reduce(0) { $0 + $1.payload.count }
        video.append(QueuedFrame(fragments: fragments, slices: slices(frameBytes: bytes, count: fragments.count, bytesPerSecond: bytesPerSecond)))
        var dropped: [UInt32] = []
        if fragments[0].key {
            // A key frame needs nothing before it: older frames not begun would only delay it (a slow key frame behind
            // frames the client discards makes it ask for another, which doubles the load).
            let keep = video.count - 1
            for i in stride(from: keep - 1, through: videoHead, by: -1) where video[i].startSlice == nil && video[i].sent == 0 {
                dropped.insert(video[i].number, at: 0)
                video.remove(at: i)
                counts.framesDropped += 1
            }
        }
        // The backlog is what waits behind the frame now leaving (a long key frame must not make the frames behind it
        // drop merely by being long); a key or repair frame and a frame begun are never dropped.
        while backlogNs > Self.maxBacklogNs,
              let i = ((videoHead + 1)..<max(video.count, videoHead + 1)).first(where: { !video[$0].restart && video[$0].startSlice == nil && video[$0].sent == 0 }) {
            dropped.append(video[i].number)
            video.remove(at: i)
            counts.framesDropped += 1
        }
        return dropped
    }

    private var backlogNs: UInt64 { video.count > videoHead + 1 ? video[(videoHead + 1)...].reduce(0) { $0 + $1.remainingNs } : 0 }

    private mutating func startTrain(_ nowNs: UInt64) {
        guard trainStartNs == nil else { return }
        trainStartNs = nowNs
        served = -1
        nextFrameSlice = 0
    }

    /// Forgets queued video and resends (a new game, a new session); urgent datagrams stay.
    mutating func discardPaced() {
        counts.framesDropped += video.count - videoHead  // unsent frames that vanish are counted, so the Host's numbers reconcile
        resend.removeAll(keepingCapacity: true); resendHead = 0
        video.removeAll(keepingCapacity: true); videoHead = 0
        resendCache = nil; videoCache = nil
        stopTrainIfIdle()
    }

    mutating func resetCounts() { counts = Counts() }

    mutating func discardAll() {
        urgent.removeAll(keepingCapacity: true); urgentHead = 0
        urgentCache = nil; blockedUntilNs = 0
        lazy = nil
        discardPaced()
    }

    /// One datagram through `emit`, with the queue's cached sealed bytes: kept while the socket refuses it.
    private mutating func send(_ d: Datagram, _ cache: WritableKeyPath<PacingQueues, Data?>,
                               _ emit: (Datagram, inout Data?) -> TransmitOutcome) -> TransmitOutcome {
        var c = self[keyPath: cache]
        let outcome = emit(d, &c)
        self[keyPath: cache] = outcome == .wouldBlock ? c : nil
        return outcome
    }

    /// Sends what is due, in order: urgent (the ones that waited: a refused socket or a backlog), resends (32 a slice),
    /// video. `emit` seals the datagram into the `inout` bytes unless they are already there, and returns what the
    /// socket did; on `.wouldBlock` the datagram stays at the head of its queue with its sealed bytes, an urgent one is
    /// retried one slice later, a paced one at the next slice.
    mutating func drain(nowNs: UInt64, emit: (Datagram, inout Data?) -> TransmitOutcome) {
        drainQueues(nowNs: nowNs, emit: emit)
        guard let d = lazy, !hasPaced, urgentHead == urgent.count, nowNs >= blockedUntilNs else { return }
        var cache: Data?
        if emit(d, &cache) == .wouldBlock { blockedUntilNs = nowNs + Self.sliceNs } else { lazy = nil }
    }

    private mutating func drainQueues(nowNs: UInt64, emit: (Datagram, inout Data?) -> TransmitOutcome) {
        if nowNs >= blockedUntilNs {
            while urgentHead < urgent.count {
                if send(urgent[urgentHead], \.urgentCache, emit) == .wouldBlock { blockedUntilNs = nowNs + Self.sliceNs; return }
                urgentHead += 1
            }
            if urgentHead == urgent.count { urgent.removeAll(keepingCapacity: true); urgentHead = 0 }
        }
        guard let start = trainStartNs, hasPaced else { return stopTrainIfIdle() }
        let slice = nowNs >= start ? Int((nowNs - start) / Self.sliceNs) : 0
        guard slice > served else { return }
        let due = start + UInt64(served + 1) * Self.sliceNs
        lateness.record(nowNs > due ? nowNs - due : 0)
        let credit = Self.resendsPerSlice * min(slice - served, Self.maxCatchUpSlices)
        served = slice
        var blocked = false
        var budget = credit
        while budget > 0, resendHead < resend.count {
            if send(.video(resend[resendHead]), \.resendCache, emit) == .wouldBlock { blocked = true; break }
            resendHead += 1; budget -= 1; counts.resent += 1
        }
        if resendHead == resend.count { resend.removeAll(keepingCapacity: true); resendHead = 0 }
        if !blocked { releaseVideo(slice: slice, emit: emit) }
        compact()
        stopTrainIfIdle()
    }

    private mutating func releaseVideo(slice: Int, emit: (Datagram, inout Data?) -> TransmitOutcome) {
        while videoHead < video.count {
            if video[videoHead].startSlice == nil {
                // A frame begins at the next free slice; after a long idle (or a late wake) it begins now, not in the past.
                video[videoHead].startSlice = nextFrameSlice >= slice - 1 ? nextFrameSlice : slice
            }
            let f = video[videoHead]
            guard let begin = f.startSlice, slice >= begin else { return }
            let n = f.fragments.count
            let reached = min(f.slices, slice - begin + 1)
            let target = (n * reached + f.slices - 1) / f.slices
            while video[videoHead].sent < target {
                if send(.video(f.fragments[video[videoHead].sent]), \.videoCache, emit) == .wouldBlock { return }
                video[videoHead].sent += 1
            }
            guard video[videoHead].sent == n else { return }
            counts.framesSent += 1
            nextFrameSlice = begin + f.slices
            videoHead += 1
        }
    }

    private mutating func compact() {
        if videoHead > 32 { video.removeFirst(videoHead); videoHead = 0 }
        if resendHead > 256 { resend.removeFirst(resendHead); resendHead = 0 }
    }

    private mutating func stopTrainIfIdle() {
        if !hasPaced { trainStartNs = nil; video.removeAll(keepingCapacity: true); videoHead = 0 }
    }

    /// The time `drain` has more to do: the next slice while resends or video wait; an urgent datagram that waited
    /// (a refused socket) one slice after the refusal, never at once (no spinning); nil while idle.
    func nextWakeNs(nowNs: UInt64) -> UInt64? {
        var wake: UInt64?
        if urgentHead < urgent.count { wake = max(nowNs, blockedUntilNs) }
        if let start = trainStartNs, hasPaced {
            let t = start + UInt64(served + 1) * Self.sliceNs
            wake = min(wake ?? t, t)
        } else if lazy != nil, urgentHead == urgent.count {
            let t = max(nowNs, blockedUntilNs)  // nothing paced waits: the slot leaves now (after a refusal, a slice later)
            wake = min(wake ?? t, t)
        }
        return wake
    }
}

/// Sends the Host's media datagrams, paced -> .claude/host.md § sender (`MediaSender` below is the handle)
///
/// One thread of its own, in the real-time (time-constraint) class, sleeps with `mach_wait_until` to each 1 ms slice
/// and drains `PacingQueues` (the pacing rules live there); a condition wakes it when work arrives while it idles. It
/// catches up after a late wake by sending every slice that is due. Urgent datagrams (pong, sound, `hostStats`) are
/// sealed and sent inline by the caller under the lock: no thread hop. The queues, sealer, address and counters sit
/// behind that one lock (an `NSCondition`); the actor holds it only to append (or, for an urgent datagram, to send
/// one), the thread to send one slice (a few dozen datagrams on a non-blocking socket). `@unchecked Sendable` for that
/// reason only. Datagrams are sealed here, at send time, in the order they leave: the receiver's replay window is 64
/// counters wide, and three queues that overtake each other would push a counter out of it if sealing happened at enqueue.
final class MediaSenderCore: @unchecked Sendable {  // every var below is touched only under `lock`

    private let lock = NSCondition()
    private var queues: PacingQueues
    private var sealer: DatagramSealer?
    private var address: UDPAddress?
    /// This session's datagrams on the wire and the sends the socket refused (the session-end line).
    private var sessionSent = 0, sessionFailed = 0
    private var bytesPerSecond = Double(HostDefaults.bitrate) / 8
    private var stopped = false
    private let socket: any MediaTransmitting
    private let clock: @Sendable () -> UInt64
    private let exited = DispatchSemaphore(value: 0)

    /// `paceMs` 0 sends every frame at once. `clock` is the monotonic time in ns (`CLOCK_UPTIME_RAW`, the clock
    /// `mach_wait_until` sleeps on, by default).
    init(socket: any MediaTransmitting, paceMs: Double, pacePeak: Double = 3,
         clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.socket = socket
        self.clock = clock
        queues = PacingQueues(paceNs: UInt64(min(max(0, paceMs), 1000) * 1e6), pacePeak: pacePeak)
        let thread = Thread { [self] in run() }
        thread.name = "nxportal.media-sender"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// From now on datagrams are sealed with `sealer` (counter 0 for a fresh session) and sent to `address`.
    func attach(sealer: DatagramSealer, address: UDPAddress?) {
        lock.lock()
        self.sealer = sealer; self.address = address
        queues.discardAll()
        queues.resetCounts()
        sessionSent = 0; sessionFailed = 0
        lock.unlock()
    }

    /// The live session ended: queued datagrams are forgotten, nothing leaves.
    func detach() {
        lock.lock()
        sealer = nil; address = nil
        queues.discardAll()
        lock.unlock()
    }

    func setAddress(_ a: UDPAddress) { lock.lock(); address = a; lock.unlock() }

    /// The session's video rate (what the pacing window is measured against).
    func setStream(bitsPerSecond: UInt32) {
        lock.lock()
        bytesPerSecond = Double(bitsPerSecond) / 8
        lock.unlock()
    }

    /// The rate `setStream` was last given.
    var streamBitsPerSecond: UInt32 { lock.lock(); defer { lock.unlock() }; return UInt32((bytesPerSecond * 8).rounded()) }

    /// Forgets queued video and resends (a new game: its frames are numbered from 0 again).
    func discardQueued() { lock.lock(); queues.discardPaced(); lock.unlock() }

    /// One datagram. An urgent one is on the wire when this returns (unless the socket refuses it: then it waits at the
    /// head of the urgent queue and the sender retries one slice later); resends leave at 32 a slice before the slice's video.
    func enqueue(_ d: Datagram, priority: MediaSender.Priority) {
        lock.lock()
        guard sealer != nil, !stopped else { lock.unlock(); return }
        switch priority {
        case .urgent:
            queues.sendUrgent(d, nowNs: clock(), emit: emit)
            if queues.hasUrgent { lock.signal() }
        case .resend:
            if case let .video(f) = d { queues.enqueueResend(f, nowNs: clock()) }
            lock.signal()
        case .lazy:
            queues.setLazy(d)
            lock.signal()
        }
        lock.unlock()
    }

    /// A frame's fragments in order. Returns the frame numbers dropped (to forget in the resend store).
    @discardableResult
    func enqueueFrame(_ fragments: [VideoFragment]) -> [UInt32] {
        lock.lock()
        guard sealer != nil, !stopped else { lock.unlock(); return [] }
        let dropped = queues.enqueueFrame(fragments, nowNs: clock(), bytesPerSecond: bytesPerSecond)
        lock.signal()
        lock.unlock()
        return dropped
    }

    var counts: PacingQueues.Counts { lock.lock(); defer { lock.unlock() }; return queues.counts }

    /// Since `attach`: datagrams sent, and sends the socket refused for a reason that will not pass.
    var sessionTotals: (sent: Int, failed: Int) { lock.lock(); defer { lock.unlock() }; return (sessionSent, sessionFailed) }

    /// Lateness of the slices since the sender was made (never reset by a new session).
    var lateness: PacingQueues.Lateness { lock.lock(); defer { lock.unlock() }; return queues.lateness }

    /// The worst slice lateness (us) since the last call (the `hostStats` field).
    func takeLateMaxUs() -> Int { lock.lock(); defer { lock.unlock() }; return queues.takeWindowMaxUs() }

    /// Ends the thread (waits for it unless `wait` is false); queued datagrams are dropped. Idempotent.
    func stop(wait: Bool = true) {
        lock.lock()
        let was = stopped
        stopped = true
        queues.discardAll()
        sealer = nil
        lock.signal()
        lock.unlock()
        if !was, wait { _ = exited.wait(timeout: .now() + 2) }
    }

    /// Under `lock`: seals into `cache` unless already sealed, and sends.
    private func emit(_ d: Datagram, _ cache: inout Data?) -> TransmitOutcome {
        guard let to = address else { return .failed }
        if cache == nil {
            guard sealer != nil, let sealed = try? sealer!.seal(type: d.type, body: d.body()) else { return .failed }
            cache = sealed
        }
        let outcome = socket.transmit(cache!, to: to)
        switch outcome {
        case .sent: sessionSent += 1
        case .failed: sessionFailed += 1
        case .wouldBlock: break
        }
        return outcome
    }

    private func run() {
        Self.makeRealtime()
        lock.lock()
        while !stopped {
            queues.drain(nowNs: clock(), emit: emit)
            let now = clock()
            if let wake = queues.nextWakeNs(nowNs: now) {
                guard wake > now else { continue }
                lock.unlock()
                Self.sleep(forNs: wake - now)
                lock.lock()
            } else {
                lock.wait()
            }
        }
        lock.unlock()
        exited.signal()
    }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    private static func ticks(_ ns: UInt64) -> UInt64 { ns * UInt64(timebase.denom) / UInt64(timebase.numer) }

    /// Precise: `mach_wait_until` on the thread's own deadline (not interruptible; one slice at most).
    private static func sleep(forNs ns: UInt64) { mach_wait_until(mach_absolute_time() + ticks(ns)) }

    /// Time-constraint class: a period of 1 ms (one slice), 300 us of computation per period (a slice's seal and send of a
    /// few dozen datagrams), due within the period; preemptible. A refusal costs precision only (logged once, ignored).
    private static func makeRealtime() {
        var policy = thread_time_constraint_policy_data_t(period: UInt32(ticks(1_000_000)), computation: UInt32(ticks(300_000)),
                                                          constraint: UInt32(ticks(1_000_000)), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(port, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        mach_port_deallocate(mach_task_self_, port)
        if result != KERN_SUCCESS { Logger(subsystem: "nxportal", category: "media").error("sender: no real-time policy (\(result))") }
    }
}
/// The sender's owner-facing handle: all the work is in `MediaSenderCore`, whose thread holds the core and never this
/// object, so a sender dropped without `stop()` ends its thread when the last reference goes (`deinit`).
final class MediaSender: Sendable {
    /// `lazy`: one slot, newest wins, leaves only when no resend or video waits (the Mac's load).
    enum Priority { case urgent, resend, lazy }
    private let core: MediaSenderCore

    init(socket: any MediaTransmitting, paceMs: Double, pacePeak: Double = 3,
         clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        core = MediaSenderCore(socket: socket, paceMs: paceMs, pacePeak: pacePeak, clock: clock)
    }

    deinit { core.stop(wait: false) }

    func attach(sealer: DatagramSealer, address: UDPAddress?) { core.attach(sealer: sealer, address: address) }
    func detach() { core.detach() }
    func setAddress(_ a: UDPAddress) { core.setAddress(a) }
    func setStream(bitsPerSecond: UInt32) { core.setStream(bitsPerSecond: bitsPerSecond) }
    var streamBitsPerSecond: UInt32 { core.streamBitsPerSecond }
    func discardQueued() { core.discardQueued() }
    func enqueue(_ d: Datagram, priority: Priority) { core.enqueue(d, priority: priority) }
    @discardableResult
    func enqueueFrame(_ fragments: [VideoFragment]) -> [UInt32] { core.enqueueFrame(fragments) }
    var counts: PacingQueues.Counts { core.counts }
    var sessionTotals: (sent: Int, failed: Int) { core.sessionTotals }
    var lateness: PacingQueues.Lateness { core.lateness }
    func takeLateMaxUs() -> Int { core.takeLateMaxUs() }
    func stop() { core.stop() }
}
#endif
