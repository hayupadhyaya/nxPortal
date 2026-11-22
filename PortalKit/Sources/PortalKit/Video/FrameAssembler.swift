import Foundation

/// What the assembler asks of its caller: a frame to decode, a `nack` datagram to send, a refresh to ask for.
public enum AssemblerEvent: Equatable, Sendable {
    case frame(AssembledFrame)
    /// Resend these fragments (at most 64; none = every fragment of the frame).
    case nack(frame: UInt32, indices: [UInt16])
    /// A frame was given up (or the stream cannot start without one): the decoder needs a restart point (a repair
    /// frame where `acceptsRepair`, else a key frame); the caller decides which to ask for.
    case refresh(lastGood: UInt32?)
}

/// Totals since the assembler was made (or restarted) -> .claude/client.md § stats
public struct AssemblerCounts: Equatable, Sendable {
    public var nacksSent, fragmentsAsked, fragmentsRecovered, framesRepaired, framesGivenUp, refreshes: Int
    /// Fragments that arrived for a frame given up within the last 200 ms: late, not lost.
    public var fragmentsLate: Int
    /// Output restarted at a repair frame; frames dropped while waiting for a restart point (never decoded, never
    /// given up one by one).
    public var restartsAtRepair: Int, framesWaited: Int
    public init(nacksSent: Int = 0, fragmentsAsked: Int = 0, fragmentsRecovered: Int = 0, framesRepaired: Int = 0,
                framesGivenUp: Int = 0, refreshes: Int = 0, fragmentsLate: Int = 0, restartsAtRepair: Int = 0, framesWaited: Int = 0) {
        self.nacksSent = nacksSent; self.fragmentsAsked = fragmentsAsked; self.fragmentsRecovered = fragmentsRecovered
        self.framesRepaired = framesRepaired; self.framesGivenUp = framesGivenUp; self.refreshes = refreshes
        self.fragmentsLate = fragmentsLate; self.restartsAtRepair = restartsAtRepair; self.framesWaited = framesWaited
    }
}

/// A frame the assembler gave up, as the rate controller needs it -> .claude/client.md § rate
public struct GivenUpFrame: Equatable, Sendable {
    public var frame: UInt32
    /// When it was given up, and when it was first seen missing something.
    public var atNs: UInt64, missingSinceNs: UInt64
    /// A fragment of it arrived after (within `lateWindowNs`): it was late, not lost.
    public var late = false
    /// Handed to `settledGiveUps` already.
    var settled = false
}

/// Puts fragments back together over a window of the newest frames, asks for what is missing, and puts frames out
/// strictly in order; never outputs a frame the decoder could not decode cleanly. A pure value type: time comes
/// from the caller -> .claude/portalkit.md § video
public struct FrameAssembler {
    public static let window = 8
    public static let maxNacks = 3
    /// A hole seen inside a frame is asked for this long after it was seen (a swap heals by itself).
    public static let settleNs: UInt64 = 1_000_000
    static let minRetryNs: UInt64 = 8_000_000
    /// A frame whose tail is missing is asked for after this long without a fragment of it (the Host sends a
    /// frame's fragments back to back), without waiting for the next frame, and only when some Host datagram (any
    /// kind) arrived at least this long after its last fragment: silence from everything is a stalled radio, not a
    /// lost tail.
    public static let tailQuietNs: UInt64 = 4_000_000
    static let giveUpSlackNs: UInt64 = 5_000_000, maxGiveUpNs: UInt64 = 50_000_000
    /// A fragment for a frame given up this recently counts as late (`fragmentsLate`); a give-up counts for the rate
    /// only once this long has passed without one (`settledGiveUps`).
    public static let lateWindowNs: UInt64 = 200_000_000, settleGiveUpNs: UInt64 = 150_000_000

    public static func retryNs(rttNs: UInt64) -> UInt64 { max(2 * rttNs, minRetryNs) }
    /// Every one of the three asks can be answered before the frame is given up (the give-up clock starts at
    /// detection, the retries at the first ask, after the settle), until the 50 ms cap.
    public static func giveUpNs(rttNs: UInt64) -> UInt64 {
        min(settleNs + 2 * retryNs(rttNs: rttNs) + rttNs + giveUpSlackNs, maxGiveUpNs)
    }

    private struct Partial {
        let frame: UInt32
        /// nil: known only by the gap in frame numbers.
        var count: Int?
        var key = false, repair = false, captureNs: UInt64 = 0, width: UInt16 = 0, height: UInt16 = 0
        var slots: [Data?] = []
        var asked: [Bool] = []
        var received = 0
        /// Highest index received; every lower one not received is missing.
        var highest = -1
        /// A later frame has arrived: every index not received is missing.
        var tailKnown = false
        var wholeAsked = false
        /// When it was first seen missing something (the give-up clock); nil while nothing is missing.
        var missingSince: UInt64?
        /// Missing indices not yet asked for, seen at this time; `urgent` = ask without the settle.
        var holeSince: UInt64?
        var urgent = false
        /// Asks of the whole known hole (the first, then retries); asks for new holes in between do not count.
        var rounds = 0
        var lastNackNs: UInt64 = 0
        var nacked = false
        /// When its newest fragment arrived (the tail rule).
        var lastFragmentNs: UInt64 = 0

        init(frame: UInt32) { self.frame = frame }

        var complete: Bool { count.map { received == $0 } ?? false }
        /// Indices known missing: below the highest received, or all once a later frame arrived.
        var knownEnd: Int { count.map { tailKnown ? $0 : max(0, highest) } ?? 0 }

        func missing(unaskedOnly: Bool) -> [UInt16] {
            guard count != nil else { return [] }
            var out: [UInt16] = []
            for i in 0..<knownEnd where slots[i] == nil && !(unaskedOnly && asked[i]) { out.append(UInt16(i)) }
            return out
        }

        /// O(1): every received index is at most `highest`.
        var missesSomething: Bool { count.map { received < (tailKnown ? $0 : highest + 1) } ?? true }
        /// Count known, the tail not seen and not yet known missing.
        var tailOpen: Bool { count.map { !tailKnown && highest < $0 - 1 } ?? false }
    }

    private let maxFrameBytes: Int
    /// Frames newer than `floor`, oldest first; at most `window`, numbers within `window` of the newest.
    private var frames: [Partial] = []
    /// Frames at or below it are ignored (put out, given up or dropped).
    private var floor: UInt32?
    private var lastOutput: UInt32?
    /// The decoder has no usable reference: only a restart point can come out next (a key frame, or a repair frame
    /// while `acceptsRepair`).
    private var awaiting = true
    /// A repair frame is a restart point: the caller's decoder holds the frames the game predicts it from (set by the
    /// caller once a key frame decoded; `awaitKeyframe` clears it) -> .claude/portalkit.md § video
    public var acceptsRepair = false
    /// The newest frame counted in `framesWaited` (each frame once).
    private var lastWaited: UInt32?
    /// The `.refresh` for this wait has been given (or the caller asked itself).
    private var signaled = false
    public private(set) var counts = AssemblerCounts()
    /// Frames given up recently (kept `lateWindowNs`, and until settled), oldest first.
    public private(set) var givenUp: [GivenUpFrame] = []

    public init(maxFrameBytes: Int = 8 << 20) { self.maxFrameBytes = maxFrameBytes }

    var hasFrameInAssembly: Bool { !frames.isEmpty }
    var windowCount: Int { frames.count }

    /// A new stream (frame numbers restart): nothing of the old one is kept, the counts included.
    public mutating func restart() { self = FrameAssembler(maxFrameBytes: maxFrameBytes) }

    /// The caller asked for a key frame itself: from now on only a key frame comes out (repair frames are no restart
    /// point until the caller sets `acceptsRepair` again); incomplete deltas are dropped, an incomplete key frame kept.
    public mutating func awaitKeyframe() {
        awaiting = true
        signaled = true
        acceptsRepair = false
        pruneUndecodable()
    }

    private func isRestart(_ p: Partial) -> Bool { p.key || (acceptsRepair && p.repair) }

    // MARK: push

    public mutating func push(_ f: VideoFragment, nowNs now: UInt64) -> [AssemblerEvent] {
        var events: [AssemblerEvent] = []
        if let floor, f.frame <= floor {
            if !givenUp.isEmpty { noteLate(f.frame, now) }
            return events
        }
        guard f.count != 0, f.index < f.count, Int(f.count) * Wire.maxVideoPayload <= maxFrameBytes else {
            // Far ahead of everything held (nothing held: of frame 0, where a stream begins): ignored; giving up through
            // it would freeze the stream.
            let newest = frames.last?.frame ?? floor
            if f.frame > newest ?? 0, f.frame - (newest ?? 0) > UInt32(Self.window) { return events }
            giveUp(through: f.frame, now, &events)
            return events
        }
        if frames.last.map({ f.frame > $0.frame }) ?? true { advance(to: f.frame, now, &events) }
        if awaiting, !(f.key || (acceptsRepair && f.repair)), !hasRestart(before: f.frame) {
            // Undecodable until a restart point: not kept, not asked for, counted once.
            if lastWaited.map({ f.frame > $0 }) ?? true { lastWaited = f.frame; counts.framesWaited += 1 }
            if !signaled { signal(&events) }
            return events
        }
        guard let i = slot(for: f.frame) else { return events }
        if frames[i].count == nil {
            let n = Int(f.count)
            frames[i].count = n; frames[i].key = f.key; frames[i].repair = f.repair; frames[i].captureNs = f.captureNs
            frames[i].width = f.width; frames[i].height = f.height
            frames[i].slots = Array(repeating: nil, count: n)
            frames[i].asked = Array(repeating: frames[i].wholeAsked, count: n)
            if frames[i].wholeAsked { counts.fragmentsAsked += n - 1 }  // the whole ask counted 1
        }
        // Scalars only: a copy of the entry would make the slot write below copy the whole array.
        guard frames[i].count == Int(f.count), frames[i].key == f.key, frames[i].repair == f.repair, frames[i].width == f.width,
              frames[i].height == f.height else {
            giveUp(through: f.frame, now, &events)
            return events
        }
        let index = Int(f.index)
        guard frames[i].slots[index] == nil else { return events }
        frames[i].slots[index] = f.payload
        frames[i].received += 1
        frames[i].lastFragmentNs = now
        if frames[i].asked[index] { counts.fragmentsRecovered += 1 }
        let highest = frames[i].highest, tailKnown = frames[i].tailKnown
        if index > highest + 1, !tailKnown { noteHoles(i, now, urgent: false) }
        frames[i].highest = max(highest, index)
        if !frames[i].missesSomething {
            frames[i].missingSince = nil; frames[i].holeSince = nil
        } else if tailKnown, frames[i].missingSince == nil {
            noteHoles(i, now, urgent: true)  // entered below a later frame: every index not received is missing
        }
        askUrgent(now, &events)
        drain(&events)
        return events
    }

    /// `frame` is newer than every frame held: the window moves, earlier frames' tails are known missing,
    /// frames skipped over are asked for whole.
    private mutating func advance(to frame: UInt32, _ now: UInt64, _ events: inout [AssemblerEvent]) {
        let lowest = frame >= UInt32(Self.window - 1) ? frame - UInt32(Self.window - 1) : 0
        // The next frame the decoder needs falls out of the window: give up everything below it.
        let needed = frames.first?.frame ?? (awaiting ? nil : lastOutput.map { $0 &+ 1 })
        if let needed, needed < lowest { giveUp(through: lowest - 1, now, &events) }
        for i in frames.indices where frames[i].missingSince == nil || !frames[i].tailKnown {
            let wasKnown = frames[i].tailKnown
            frames[i].tailKnown = true
            guard frames[i].missesSomething else { continue }
            if wasKnown { frames[i].missingSince = now } else { noteHoles(i, now, urgent: true) }  // a quiet tail, proven
        }
        // Whole frames skipped: from after the newest held (or the next to output) up to `frame`.
        let first: UInt32? = frames.last.map { $0.frame &+ 1 } ?? (awaiting ? nil : lastOutput.map { $0 &+ 1 })
        // While awaiting, only frames after a restart point can decode (a wholly lost one: the caller's requests).
        guard var n = first.map({ max($0, lowest) }), !awaiting || hasRestart(before: frame) else { return }
        while n < frame {
            var p = Partial(frame: n)
            p.tailKnown = true
            p.missingSince = now; p.holeSince = now; p.urgent = true
            frames.append(p)
            n += 1
        }
    }

    /// Index of `frame`'s entry, made if new (kept in order); nil if it cannot be held.
    private mutating func slot(for frame: UInt32) -> Int? {
        var p = Partial(frame: frame)
        let at: Int
        if let i = frames.lastIndex(where: { $0.frame <= frame }) {
            if frames[i].frame == frame { return i }
            at = i + 1
        } else {
            at = 0
        }
        p.tailKnown = at < frames.count  // a later frame has arrived
        frames.insert(p, at: at)
        return at
    }

    private func hasRestart(before frame: UInt32) -> Bool { frames.contains { isRestart($0) && $0.frame < frame } }

    private mutating func noteHoles(_ i: Int, _ now: UInt64, urgent: Bool) {
        if frames[i].missingSince == nil { frames[i].missingSince = now }
        if frames[i].holeSince == nil { frames[i].holeSince = now }
        if urgent { frames[i].urgent = true }
    }

    // MARK: tick

    /// Retries, asks for holes past the settle, gives up. `rttNs` = the measured round trip (the caller's default
    /// before the first measurement). `heardNs` = when the newest Host datagram of any kind arrived (nil: now, the link
    /// is taken as alive); a quiet tail is asked for only when it is at least `tailQuietNs` after the frame's last fragment.
    public mutating func tick(nowNs now: UInt64, rttNs: UInt64, heardNs: UInt64? = nil) -> [AssemblerEvent] {
        let heard = heardNs ?? now
        var events: [AssemblerEvent] = []
        let giveUpNs = Self.giveUpNs(rttNs: rttNs), retryNs = Self.retryNs(rttNs: rttNs)
        if let g = frames.last(where: { $0.missingSince.map { now >= $0 &+ giveUpNs } ?? false }) {
            giveUp(through: g.frame, now, &events)
        }
        for i in frames.indices {
            if frames[i].tailOpen, now >= frames[i].lastFragmentNs &+ Self.tailQuietNs,
               heard >= frames[i].lastFragmentNs &+ Self.tailQuietNs {
                // Asked for at once, but the give-up clock waits for proof (a later frame): a stall holds everything.
                frames[i].tailKnown = true
                frames[i].holeSince = now
                frames[i].urgent = true
            }
            if let h = frames[i].holeSince, frames[i].urgent || now >= h &+ Self.settleNs { ask(i, all: false, now, &events) }
            if frames[i].nacked, frames[i].rounds < Self.maxNacks, now >= frames[i].lastNackNs &+ retryNs,
               frames[i].missesSomething {
                ask(i, all: true, now, &events)
            }
        }
        drain(&events)
        return events
    }

    /// A frame with a known count is waiting for its tail.
    public var hasOpenTail: Bool { frames.contains { $0.tailOpen } }

    /// The earliest time `tick` has something to do; nil while nothing is missing. A quiet tail counts only once a
    /// datagram has been heard after its quiet spell (`heardNs`; nil: now): until then a datagram wakes the caller.
    public func nextTickNs(rttNs: UInt64, heardNs: UInt64? = nil) -> UInt64? {
        let giveUpNs = Self.giveUpNs(rttNs: rttNs), retryNs = Self.retryNs(rttNs: rttNs)
        var next: UInt64?
        func consider(_ t: UInt64) { next = min(next ?? t, t) }
        for p in frames {
            if let m = p.missingSince { consider(m &+ giveUpNs) }
            if let h = p.holeSince { consider(p.urgent ? h : h &+ Self.settleNs) }
            if p.nacked, p.rounds < Self.maxNacks, p.missesSomething { consider(p.lastNackNs &+ retryNs) }
            if p.tailOpen, heardNs.map({ $0 >= p.lastFragmentNs &+ Self.tailQuietNs }) ?? true { consider(p.lastFragmentNs &+ Self.tailQuietNs) }
        }
        return next
    }

    private mutating func askUrgent(_ now: UInt64, _ events: inout [AssemblerEvent]) {
        for i in frames.indices where frames[i].urgent && frames[i].holeSince != nil { ask(i, all: false, now, &events) }
    }

    /// `all`: a retry of every known missing index (a round); else only the ones never asked for.
    private mutating func ask(_ i: Int, all: Bool, _ now: UInt64, _ events: inout [AssemblerEvent]) {
        // In place: a copy of the entry would make the `asked` writes copy the array.
        frames[i].holeSince = nil
        frames[i].urgent = false
        let frame = frames[i].frame
        if frames[i].count == nil {
            events.append(.nack(frame: frame, indices: []))
            counts.nacksSent += 1
            counts.fragmentsAsked += 1
            frames[i].wholeAsked = true
        } else {
            let indices = frames[i].missing(unaskedOnly: !all)
            guard !indices.isEmpty else { return }
            for index in indices { frames[i].asked[Int(index)] = true }
            var start = 0
            while start < indices.count {
                let end = min(start + Datagram.maxNackIndices, indices.count)
                events.append(.nack(frame: frame, indices: Array(indices[start..<end])))
                counts.nacksSent += 1
                start = end
            }
            counts.fragmentsAsked += indices.count
        }
        // The retry clock follows the rounds: an ask for a newly found hole does not push the retry back.
        if all || !frames[i].nacked { frames[i].rounds += 1; frames[i].lastNackNs = now }
        frames[i].nacked = true
    }

    // MARK: out

    /// Puts out every frame that can go, in order.
    private mutating func drain(_ events: inout [AssemblerEvent]) {
        while let p = frames.first {
            if p.complete, p.key || (awaiting && isRestart(p)) || (!awaiting && lastOutput.map({ p.frame == $0 &+ 1 }) ?? false) {
                frames.removeFirst()
                output(p, &events)
            } else if let k = frames.firstIndex(where: { $0.complete && ($0.key || (awaiting && isRestart($0))) }) {
                // A complete key frame needs nothing before it, nor does a repair frame the output waits for: the
                // frames before it are dropped and counted, not given up one by one.
                if awaiting { dropWaiting(k) } else { frames.removeFirst(k) }
                floor = frames[0].frame - 1
            } else {
                break
            }
        }
    }

    private mutating func output(_ p: Partial, _ events: inout [AssemblerEvent]) {
        floor = p.frame
        lastOutput = p.frame
        if awaiting, !p.key, p.repair { counts.restartsAtRepair += 1 }  // a repair frame put out as a restart point
        if isRestart(p) { awaiting = false; signaled = false }
        if p.nacked { counts.framesRepaired += 1 }
        var data = Data(capacity: p.slots.reduce(0) { $0 + ($1?.count ?? 0) })
        for s in p.slots { data.append(s ?? Data()) }
        events.append(.frame(AssembledFrame(frame: p.frame, key: p.key, repair: p.repair, captureNs: p.captureNs,
                                            width: p.width, height: p.height, data: data)))
    }

    /// Frames up to and including `frame` are dropped; only a restart point can come out next.
    private mutating func giveUp(through frame: UInt32, _ now: UInt64, _ events: inout [AssemblerEvent]) {
        let dropped = frames.filter { $0.frame <= frame }.count
        counts.framesGivenUp += max(dropped, 1)
        prune(now)
        for p in frames where p.frame <= frame {
            givenUp.append(GivenUpFrame(frame: p.frame, atNs: now, missingSinceNs: p.missingSince ?? now))
        }
        if dropped == 0 { givenUp.append(GivenUpFrame(frame: frame, atNs: now, missingSinceNs: now)) }
        frames.removeAll { $0.frame <= frame }
        floor = max(floor ?? frame, frame)
        awaiting = true
        pruneUndecodable()
        if !signaled { signal(&events) }
    }

    private mutating func signal(_ events: inout [AssemblerEvent]) {
        signaled = true
        counts.refreshes += 1
        events.append(.refresh(lastGood: lastOutput))
    }

    /// While awaiting: frames before the first restart point in the window cannot decode (and are not asked for).
    private mutating func pruneUndecodable() {
        guard awaiting else { return }
        dropWaiting(frames.firstIndex(where: { isRestart($0) }) ?? frames.count)
    }

    /// The first `k` frames held cannot decode while the output waits: dropped and counted, each frame once.
    private mutating func dropWaiting(_ k: Int) {
        guard k > 0 else { return }
        for p in frames.prefix(k) where lastWaited.map({ p.frame > $0 }) ?? true { counts.framesWaited += 1 }
        lastWaited = max(lastWaited ?? 0, frames[k - 1].frame)
        frames.removeFirst(k)
    }

    // MARK: late

    /// A fragment of a frame at or below the floor: late if that frame was given up within `lateWindowNs`.
    private mutating func noteLate(_ frame: UInt32, _ now: UInt64) {
        guard let i = givenUp.lastIndex(where: { $0.frame == frame }), now >= givenUp[i].atNs, now - givenUp[i].atNs <= Self.lateWindowNs else { return }
        counts.fragmentsLate += 1
        givenUp[i].late = true
    }

    /// Drops what is older than the late window and settled or late; keeps 64 at most.
    private mutating func prune(_ now: UInt64) {
        givenUp.removeAll { now >= $0.atNs && now - $0.atNs > Self.lateWindowNs && ($0.settled || $0.late) }
        if givenUp.count > 64 { givenUp.removeFirst(givenUp.count - 64) }  // nobody settles them (a fixed rate)
    }

    /// Frames given up at least `settleGiveUpNs` ago with no late fragment since, each counted once: what the rate
    /// controller takes as given up (a late arrival cancels a give-up; a delayed burst is not a shortage).
    public mutating func settledGiveUps(nowNs now: UInt64) -> Int {
        var n = 0
        for i in givenUp.indices where !givenUp[i].settled && !givenUp[i].late && now >= givenUp[i].atNs &+ Self.settleGiveUpNs {
            givenUp[i].settled = true
            n += 1
        }
        prune(now)
        return n
    }
}
