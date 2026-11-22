import Foundation

/// What the session saw since the previous sample (every 200 ms, and at once when a frame is given up)
/// -> .claude/client.md § rate
public struct RateSample: Equatable, Sendable {
    /// When the sample was taken (`uptimeNs()`).
    public var nowNs: UInt64
    /// Frames the assembler gave up, fragments it asked for again, video fragments that arrived (resends included).
    public var framesGivenUp: Int, fragmentsAsked: Int, fragmentsReceived: Int
    /// Frames put out (complete) since the previous sample.
    public var framesCompleted: Int
    /// Frames given up since the previous sample, settled or not (`framesGivenUp` counts only settled ones): only for
    /// telling, inside a cut's hold, that the picture has not come back.
    public var framesGivenUpRecent = 0
    /// Video payload received over the last 300 ms, bit/s (0 = not known yet: the stream is younger than that).
    public var deliveredBps: Double
    /// What the encoder produced (frame sizes as their fragments tell them, lost fragments included), bit/s: over the
    /// last second (`producedBps`) and over the delivered window (`producedRecentBps`); 0 = not known.
    public var producedBps: Double, producedRecentBps: Double
    /// Video payload bytes received since the previous sample.
    public var bytesReceived: Int
    /// The lowest ping round trip of the last 300 ms (nil under 2 pongs in it): a queue on the way delays every pong.
    public var rttFloorNs: UInt64?
    /// The median ping round trip.
    public var rttNs: UInt64

    public init(nowNs: UInt64, framesGivenUp: Int = 0, fragmentsAsked: Int = 0, fragmentsReceived: Int, framesCompleted: Int = 0,
                deliveredBps: Double, producedBps: Double = 0, producedRecentBps: Double = 0, bytesReceived: Int = 0,
                rttFloorNs: UInt64? = nil, rttNs: UInt64 = 4_000_000) {
        self.nowNs = nowNs; self.framesGivenUp = framesGivenUp; self.fragmentsAsked = fragmentsAsked
        self.fragmentsReceived = fragmentsReceived; self.framesCompleted = framesCompleted; self.deliveredBps = deliveredBps
        self.producedBps = producedBps; self.producedRecentBps = producedRecentBps; self.bytesReceived = bytesReceived
        self.rttFloorNs = rttFloorNs; self.rttNs = rttNs
    }
}

/// Why the rate last changed -> .claude/client.md § rate
public enum RateReason: String, Sendable, Equatable {
    /// The first rate, or the ceiling the user lowered under it; the climb before any trouble, or back to the memory; a probe above it.
    case start, climb, probe
    /// Cuts: the ping floor rose (a queue); fragments asked again; frames given up; under half the rate delivered since
    /// a cut; frames still given up and none completed after a cut.
    case queue, loss, givenUp, measured, frozen
}

/// The video rate the client asks of the Host, below the user's ceiling; a value type with no clock of its own (time
/// and samples come from the caller) -> .claude/client.md § rate
public struct RateController: Sendable {
    public static let floorBps: UInt32 = 2_000_000
    /// The session feeds a sample this often.
    public static let samplePeriodNs: UInt64 = 200_000_000
    /// A session starts at half the ceiling, not under this (unless the ceiling is).
    static let startMinBps: UInt32 = 10_000_000
    /// Trouble: fragments asked for again over fragments received in the last second above this share, or this many
    /// frames given up in it (an isolated one is a loss run repair missed, not a shortage), while the sample has some.
    static let lossShare = 0.10, givenUpTrouble = 2, lossWindowNs: UInt64 = 1_000_000_000
    /// Trouble at once: over this share asked again in one sample of at least `sharpMinFragments` (a link that fell away).
    static let sharpShare = 0.20, sharpMinFragments = 100
    /// Queue trouble: the ping floor (lowest round trip of the last 300 ms) above its 30 s minimum by more than
    /// `max(15 ms, 2 x minimum)`. Frame delay is no signal: a busy picture raises it with no queue anywhere.
    static let queueRiseMinNs: UInt64 = 15_000_000, rttMinWindowSeconds = 30
    /// A cut is 0.7 x the rate, never under 0.7 x what the encoder produced in the last second. With loss trouble, the
    /// encoder producing at least half the rate over the delivered window and the link delivering under 0.9 x that (the
    /// link is the limit, not a quiet or just-changed picture), 0.85 x delivered when lower.
    static let cutFactor = 0.7, deliveredFactor = 0.85, linkShare = 0.9, demandShare = 0.5
    /// After a cut no further cut for `max(400 ms, 4 x rtt)` after the Host could have applied it (half a round trip,
    /// plus what is left of the Host's 250 ms between configs after the change before), and no increase for 5 s.
    static let cutShowsNs: UInt64 = 400_000_000, hostApplyNs: UInt64 = 250_000_000, noIncreaseNs: UInt64 = 5_000_000_000
    /// Inside that hold, 200 ms or more after a cut: trouble with the link delivering (since the cut) under half the rate
    /// cuts to 0.85 x that (the cut was sized from a window from before the shortage showed); frames still given up
    /// with none completed (the picture has not come back: the refresh did not fit) cuts 0.7 x again.
    static let measuredAfterNs: UInt64 = 200_000_000, measuredShare = 0.5
    /// Trouble after at least this long clean starts a new episode: the memory is the rate when an episode began.
    static let episodeGapNs: UInt64 = 1_000_000_000
    /// Until the first trouble: + 25 % per clean second. Any increase needs the encoder to have produced at least half
    /// the rate over the last second (`demandShare`; 0 = not known, taken as yes).
    static let startClimb = 0.25
    /// After trouble: back to 90 % of the trouble rate in 4 equal steps, one per clean second.
    static let returnShare = 0.9, returnSteps = 4.0
    /// Probing above the remembered rate: after 30 clean seconds, + 5 % every 5 clean seconds.
    static let probeAfterNs: UInt64 = 30_000_000_000, probeEveryNs: UInt64 = 5_000_000_000, probeStep = 0.05
    /// The memory fades after 60 full, clean seconds above it (quiet seconds pause the count) (the fast climb is allowed again).
    static let fadeAfterNs: UInt64 = 60_000_000_000
    /// A sample this long after the one before (the session was suspended) is no evidence.
    static let lateSampleNs: UInt64 = 1_000_000_000
    /// A sample with nothing received this soon after the one before is short, not a stall.
    static let shortSampleNs: UInt64 = 100_000_000
    static let secondNs: UInt64 = 1_000_000_000

    public private(set) var ceilingBps: UInt32
    public private(set) var rateBps: UInt32
    /// Cuts so far.
    public private(set) var cuts = 0
    /// The rate at which the last trouble episode began (what the link delivered when that rate had not run clean and the link
    /// showed itself the limit); nil before the first trouble or once it has faded.
    public private(set) var memoryBps: UInt32?

    private var lastSampleNs: UInt64?
    /// Start of the current clean stretch (nil right after trouble or a sample that is no evidence).
    private var cleanSinceNs: UInt64?
    private var lastIncreaseNs: UInt64 = 0
    private var holdUntilNs: UInt64 = 0
    private var lastCutNs: UInt64?
    /// When the rate last changed (the Host's 250 ms between configs counts from there); bytes received since the last cut.
    private var lastChangeNs: UInt64?
    private var bytesSinceCut = 0
    private var noIncreaseUntilNs: UInt64 = 0
    /// Where the climb back to the memory began (the cut's rate).
    private var climbFromBps: UInt32 = 0
    /// The current rate has run clean for a second with demand: a rate that has not is no memory.
    private var rateRanClean = false
    /// Full, clean time spent above the memory; a quiet second pauses it, trouble or a rate at or under the memory resets it.
    private var aboveMemoryFullNs: UInt64 = 0
    /// The current episode began below the memory: its link-limited cuts lower the memory too.
    private var belowMemory = false
    /// The memory is only the rate an unproven episode began at (no link evidence): any trouble under it lowers it.
    private var memoryGuess = false
    /// Why the rate last changed.
    public private(set) var reason: RateReason = .start
    /// The 30 s minimum of the ping floor, as of the last sample that had one.
    public private(set) var rttMinNs: UInt64?

    /// Per-second ping floor minima of the last 30 s (slot = second % 30; `minSecond` says which second a slot holds).
    private var minRtt = [UInt64](repeating: .max, count: RateController.rttMinWindowSeconds)
    private var minSecond = [UInt64](repeating: .max, count: RateController.rttMinWindowSeconds)
    /// The last second of samples for the loss share: a fixed ring (64: refresh samples come between the 200 ms ones).
    private var loss = [(atNs: UInt64, asked: Int, received: Int, givenUp: Int)](repeating: (0, 0, 0, 0), count: 64)
    private var lossNext = 0

    public init(ceilingBps: UInt32) {
        let ceiling = max(ceilingBps, Self.floorBps)
        self.ceilingBps = ceiling
        rateBps = ceiling <= Self.startMinBps ? ceiling : max(ceiling / 2, Self.startMinBps)
    }

    /// The user changed the ceiling while the session runs (never under `floorBps`). Lowered under the rate: the rate is the
    /// new ceiling at once, returned (not a cut: no trouble, so no hold and the cut count and the memory stay). Raised: nothing
    /// changes now; the rate rises by the normal climb only (a memory above the lowered ceiling does not make it jump).
    @discardableResult
    public mutating func setCeiling(_ bps: UInt32) -> UInt32? {
        ceilingBps = max(bps, Self.floorBps)
        guard rateBps > ceilingBps else { return nil }
        rateBps = ceilingBps
        rateRanClean = false
        reason = .start
        return rateBps
    }

    /// The new rate when it changed, else nil.
    public mutating func update(_ s: RateSample) -> UInt32? {
        let now = s.nowNs
        defer { lastSampleNs = now }
        let late = lastSampleNs.map { now < $0 || now - $0 > Self.lateSampleNs } ?? false
        bytesSinceCut += s.bytesReceived
        if late || s.fragmentsReceived == 0 {
            // A late sample or a stall: no evidence either way. A refresh sample right after another is just short.
            let short = lastSampleNs.map { now >= $0 && now - $0 < Self.shortSampleNs } ?? false
            if !(short && !late) { cleanSinceNs = nil }
            return nil
        }
        let (loss, queue) = trouble(s)
        if loss != nil || queue { return troubleSeen(s, loss: loss, queue: queue) }
        // A clean second says the link carries the rate only when the stream used it: a quiet picture proves nothing.
        // Proving a rate, probing above the memory and fading it need the encoder to fill the rate (0.9 x).
        let full = s.producedBps == 0 || s.producedBps >= Self.linkShare * Double(rateBps)
        return clean(now, mayIncrease: s.producedBps == 0 || s.producedBps >= Self.demandShare * Double(rateBps), full: full)
    }

    // MARK: trouble

    /// The loss kind (nil: none) and whether the ping floor shows a queue.
    private mutating func trouble(_ s: RateSample) -> (loss: RateReason?, queue: Bool) {
        var kind: RateReason?, queue = false
        loss[lossNext] = (s.nowNs, s.fragmentsAsked, s.fragmentsReceived, s.framesGivenUp)
        lossNext = (lossNext + 1) % loss.count
        var asked = 0, received = 0, givenUp = 0
        for e in loss where e.atNs != 0 && e.atNs <= s.nowNs && s.nowNs - e.atNs < Self.lossWindowNs {
            asked += e.asked; received += e.received; givenUp += e.givenUp
        }
        // Only while it goes on: a past sample in the window does not keep the trouble alive.
        if s.fragmentsAsked > 0, received > 0, Double(asked) > Self.lossShare * Double(received) { kind = .loss }
        if s.fragmentsReceived >= Self.sharpMinFragments, Double(s.fragmentsAsked) > Self.sharpShare * Double(s.fragmentsReceived) { kind = .loss }
        if s.framesGivenUp > 0, givenUp >= Self.givenUpTrouble { kind = .givenUp }
        if let floor = s.rttFloorNs {
            let base = noteRtt(floor, at: s.nowNs)
            rttMinNs = base
            if floor > base, floor - base > max(Self.queueRiseMinNs, 2 * base) { queue = true }
        }
        return (kind, queue)
    }

    /// Records `floor` for its second; the minimum of the last 30 s, this sample included.
    private mutating func noteRtt(_ floor: UInt64, at now: UInt64) -> UInt64 {
        let sec = now / Self.secondNs, slot = Int(sec % UInt64(minRtt.count))
        if minSecond[slot] != sec { minSecond[slot] = sec; minRtt[slot] = floor } else { minRtt[slot] = min(minRtt[slot], floor) }
        var base = UInt64.max
        for i in 0..<minRtt.count where minSecond[i] != .max && minSecond[i] <= sec && sec - minSecond[i] < UInt64(minRtt.count) {
            base = min(base, minRtt[i])
        }
        return base
    }

    /// What the link carries, when loss trouble shows it is the limit: `delivered` (> 0) under 0.9 x `produced`, which
    /// is at least half `rate`.
    private static func linkLimit(_ loss: RateReason?, delivered: Double, produced: Double, rate: Double) -> Double? {
        guard loss != nil, delivered > 0, produced >= Self.demandShare * rate, delivered < Self.linkShare * produced else { return nil }
        return delivered
    }

    private mutating func troubleSeen(_ s: RateSample, loss: RateReason?, queue: Bool) -> UInt32? {
        let now = s.nowNs
        let cleanFor = cleanSinceNs.flatMap { c in lastSampleNs.map { $0 > c ? $0 - c : 0 } } ?? 0
        cleanSinceNs = nil
        aboveMemoryFullNs = 0
        let rate = Double(rateBps)
        var next: Double, why: RateReason
        // Delivered counts only when the link is the limit: a quiet picture delivers little on a good link.
        let link = Self.linkLimit(loss, delivered: s.deliveredBps, produced: s.producedRecentBps, rate: rate)
        var belowProduced = link != nil
        var unprovenStart = false
        let sinceCut = lastCutNs.flatMap { now > $0 ? Double(bytesSinceCut) * 8 / (Double(now - $0) / 1e9) : nil }
        if now >= holdUntilNs {
            if lastCutNs == nil || cleanFor >= Self.episodeGapNs {  // a new episode
                // Trouble below the memory (climbing back, or holding under it): the link is lower than remembered.
                belowMemory = memoryBps.map { rateBps < $0 } ?? false
                // Loss with no link evidence and no queue under a measured memory is a burst, not the link: it stays.
                if belowMemory {
                    if link != nil || queue || memoryGuess { memoryBps = UInt32(min(rate, link ?? rate)); memoryGuess = false }
                } else if rateRanClean { memoryBps = rateBps; memoryGuess = false }
                else {  // never ran clean: the memory is what it was (a probe above it); with none, the link, else this rate
                    unprovenStart = memoryBps == nil; belowMemory = true
                }
            }
            next = Self.cutFactor * rate
            if let link { next = min(next, Self.deliveredFactor * link) }
            why = loss ?? .queue
        } else if let last = lastCutNs, now - last >= Self.measuredAfterNs, let d = sinceCut, d > 0, d < Self.measuredShare * rate,
                  let l = Self.linkLimit(loss, delivered: d, produced: s.producedRecentBps, rate: rate) {
            next = Self.deliveredFactor * l  // the link carries far less than the cut assumed
            why = .measured; belowProduced = true
        } else if loss != nil, let last = lastCutNs, now - last >= Self.measuredAfterNs,
                  s.framesGivenUp > 0 || s.framesGivenUpRecent > 0, s.framesCompleted == 0 {
            next = Self.cutFactor * rate  // frames still given up and none came: the refresh did not get through the cut
            why = .frozen; belowProduced = true
        } else {
            return nil  // the last cut has not had time to show
        }
        if !belowProduced { next = max(next, Self.cutFactor * s.producedBps) }
        // A cut is always below the rate: when 0.7 x produced reaches it, 0.7 x the rate (the floor bounds it below).
        if next >= rate { next = Self.cutFactor * rate }
        // In an episode under the memory, any sample that shows the link lowers it (the first cut may be a queue's).
        if belowMemory, let link, let m = memoryBps, link < Double(m) { memoryBps = UInt32(link); memoryGuess = false }
        let cut = UInt32(min(max(next, Double(Self.floorBps)), Double(ceilingBps)).rounded())
        if unprovenStart { memoryBps = UInt32(min(link ?? rate, rate)); memoryGuess = link == nil }
        rateRanClean = false
        let apply = (lastChangeNs.map { $0 + Self.hostApplyNs > now ? $0 + Self.hostApplyNs - now : 0 } ?? 0) + s.rttNs / 2
        lastCutNs = now
        bytesSinceCut = 0
        holdUntilNs = now + apply + max(Self.cutShowsNs, 4 * s.rttNs)
        noIncreaseUntilNs = now + Self.noIncreaseNs
        climbFromBps = cut
        guard cut != rateBps else { return nil }  // at the floor already
        cuts += 1
        rateBps = cut
        reason = why
        lastChangeNs = now
        return cut
    }

    // MARK: clean

    private mutating func clean(_ now: UInt64, mayIncrease: Bool, full: Bool) -> UInt32? {
        let since = cleanSinceNs ?? lastSampleNs ?? now
        cleanSinceNs = since
        if mayIncrease, full, now - max(since, lastChangeNs ?? 0) >= Self.secondNs { rateRanClean = true }
        if let m = memoryBps {
            if rateBps > m {
                // Only full, clean seconds count; a quiet picture above the memory proves nothing either way.
                if mayIncrease, full, let last = lastSampleNs, now > last { aboveMemoryFullNs += now - last }
                if aboveMemoryFullNs >= Self.fadeAfterNs { memoryBps = nil; aboveMemoryFullNs = 0 }  // the fast climb again
            } else {
                aboveMemoryFullNs = 0
            }
        }
        guard mayIncrease, rateBps < ceilingBps, now >= noIncreaseUntilNs, now - since >= Self.secondNs,
              now - lastIncreaseNs >= Self.secondNs else { return nil }
        let rate = Double(rateBps)
        var next: Double, why = RateReason.climb
        if let m = memoryBps.map(Double.init) {
            let target = (Self.returnShare * m).rounded()  // whole bit/s, as the rate is: else the climb stops under it
            if rate < target {
                next = min(target, rate + max((target - Double(climbFromBps)) / Self.returnSteps, 500_000))
            } else {
                guard full, now - since >= Self.probeAfterNs, now - lastIncreaseNs >= Self.probeEveryNs else { return nil }
                next = rate * (1 + Self.probeStep)
                why = .probe
            }
        } else {
            next = rate * (1 + Self.startClimb)
        }
        let up = UInt32(min(next, Double(ceilingBps)).rounded())
        guard up > rateBps else { return nil }
        rateBps = up
        rateRanClean = false
        reason = why
        lastIncreaseNs = now
        lastChangeNs = now
        return up
    }
}
