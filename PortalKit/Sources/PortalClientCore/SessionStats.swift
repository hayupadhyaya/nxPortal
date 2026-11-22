import Foundation
import PortalKit

/// Local monotonic time, the clock `captureNs` and `hostNs` also use on the Mac; display marks are taken with it.
public func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

public struct AudioBlock: Sendable {
    public var seq: UInt32, captureNs: UInt64, pcm: Data
    public init(seq: UInt32, captureNs: UInt64, pcm: Data) { self.seq = seq; self.captureNs = captureNs; self.pcm = pcm }
}

/// Largest values since the recorder's previous read (once a second); nil when there was no sample.
/// Separate from `SessionStats`: the panel reads those as often as it likes and must not reset them.
public struct SecondMaxima: Sendable, Equatable {
    /// Largest interval between two video datagrams as the session received them, ms.
    public var netGapMaxMs: Double?
    /// Largest ping / pong round trip, ms.
    public var rttMaxMs: Double?
    public init(netGapMaxMs: Double? = nil, rttMaxMs: Double? = nil) { self.netGapMaxMs = netGapMaxMs; self.rttMaxMs = rttMaxMs }
}

public struct SessionStats: Sendable, Equatable {
    public var framesShown = 0, framesSkipped = 0, keyRequests = 0, audioLost = 0
    /// Display marks (`markDisplayed`): pictures handed to the display layer.
    public var framesDisplayed = 0
    public var fps = 0.0, p95DelayMs = 0.0
    /// Capture to hand-off to the display (`markDisplayed`), over the last 600 marked frames; 0 when none.
    public var p95DisplayMs = 0.0
    public var clockOffsetNs: Int64 = 0
    /// Video payload received in the last 2 s, Mbit/s.
    public var bitrateMbps = 0.0
    /// Median of the last 9 ping / pong round trips; 0 before the first pong.
    public var rttMs = 0.0
    /// The ping floor (lowest round trip of the last 300 ms, `§ rate`); nil when there is none yet.
    public var rttFloorMs: Double?
    /// Median of the same samples as `p95DisplayMs`.
    public var p50DisplayMs = 0.0
    /// Time between consecutive completed frames over the last 2 s (16.7 ms ideal at 60 fps).
    public var p95ArrivalGapMs = 0.0, maxArrivalGapMs = 0.0
    /// Completed frames whose capture time is more than 1.5 frame periods after the frame before: pictures the Mac
    /// never sent (the game hitched, or the Mac's rate cap refused one), total since the stream started.
    public var sourceGaps = 0
    /// Frames per second by capture time over the last 2 s (the Mac's own rate, whatever the network did).
    public var sourceFps = 0.0
    /// Loss repair, totals since the video stream started (`FrameAssembler.counts`) -> .claude/client.md § stats:
    /// `nack` datagrams sent; fragments asked for (a frame asked for whole counts its fragments once they are known);
    /// asked-for fragments that arrived; frames put out after a `nack`; frames given up; restarts at a repair frame
    /// (`refreshes`); restart points asked for (frames given up, or a stream that cannot start); frames dropped while
    /// waiting for a restart point.
    public var nacksSent = 0, fragmentsAsked = 0, fragmentsRecovered = 0, framesRepaired = 0, framesGivenUp = 0, refreshes = 0
    public var restartsAsked = 0, framesWaited = 0
    /// Over the session: `repair` requests sent, escalations to a key request (no restart point in time), key frames
    /// decoded after the first, frames the player reported it could not decode, `ack`s sent -> .claude/client.md § repair
    public var repairRequests = 0, escalations = 0, keys = 0, decodeErrors = 0, acksSent = 0
    /// Fragments that arrived for a frame given up within 200 ms before (late, not lost).
    public var fragmentsLate = 0
    /// Size of the newest key frame; 0 before the first.
    public var width = 0, height = 0
    /// The newest `hostStats` from the Host (once a second); nil until the first.
    public var host: HostStats?
    /// The newest `load` from the Host (only while the device's panel is at "full") and when it arrived (the session's uptime
    /// ns); nil until the first.
    public var load: HostLoad?
    public var loadAtNs: UInt64 = 0
    /// The rate the session asks for now, its ceiling (the wish), and the cuts so far (bit/s; rate and cuts 0 when the
    /// rate is fixed) -> .claude/client.md § rate. What the Host applied is `host?.rateBps`.
    public var rateBps: UInt32 = 0, rateCeilingBps: UInt32 = 0, rateCuts = 0
    /// The rate's newest changes (at most 32, oldest first), each with what the controller saw.
    public var rateChanges: [RateChange] = []
    /// The first rate asked and the lowest one over the session (0 = no change yet); unlike `rateChanges` they do not roll.
    public var rateStartBps: UInt32 = 0, rateLowBps: UInt32 = 0

    public init() {}
}

/// One change of the rate and the evidence behind it -> .claude/client.md § rate
public struct RateChange: Equatable, Sendable {
    /// Counts from 1 over the session (a reader prints the ones it has not seen).
    public var seq: Int
    /// Seconds since the media started.
    public var atSeconds: Double
    public var fromBps: UInt32, toBps: UInt32
    public var why: RateReason
    /// The ping floor's 30 s minimum and the floor in the sample (ms; 0 = none yet); delivered (300 ms) and produced
    /// (1 s) video, bit/s.
    public var rttMinMs: Double, rttFloorMs: Double, deliveredBps: Double, producedBps: Double

    public init(seq: Int, atSeconds: Double, fromBps: UInt32, toBps: UInt32, why: RateReason, rttMinMs: Double = 0,
                rttFloorMs: Double = 0, deliveredBps: Double = 0, producedBps: Double = 0) {
        self.seq = seq; self.atSeconds = atSeconds; self.fromBps = fromBps; self.toBps = toBps; self.why = why
        self.rttMinMs = rttMinMs; self.rttFloorMs = rttFloorMs; self.deliveredBps = deliveredBps; self.producedBps = producedBps
    }

    /// `rate t=<s> <from>-><to> why=<why> rtt_min=<ms> rtt_floor=<ms> delivered=<Mbit/s> produced=<Mbit/s>`
    public var line: String {
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        return String(format: "rate t=%.2f ", atSeconds) + "\(f(Double(fromBps) / 1e6))->\(f(Double(toBps) / 1e6)) why=\(why.rawValue)"
            + " rtt_min=\(f(rttMinMs)) rtt_floor=\(f(rttFloorMs)) delivered=\(f(deliveredBps / 1e6)) produced=\(f(producedBps / 1e6))"
    }
}

/// The counters behind `SessionStats`; a value type with no clock of its own -> .claude/client.md § stats
struct StatsTracker {
    /// Pongs come 10 a second: the clock offset is the best of the last 2.5 s, the median round trip of the last 2.3 s.
    static let delayWindow = 600, pongWindow = 25, rttWindow = 23
    /// The ping floor: the lowest round trip of the last 300 ms, from at least 2 pongs on cadence -> .claude/client.md § rate
    static let rttFloorNs: UInt64 = 300_000_000, rttFloorMinPongs = 2
    /// Pong arrivals further apart than this are off cadence (a pause): pongs sent before the gap's end are not used.
    static let rttCadenceGapNs: UInt64 = 150_000_000
    static let fpsWindowNs: UInt64 = 2_000_000_000

    private(set) var stats = SessionStats()
    private let startNs: UInt64
    /// First frame of the current video stream; the rates divide by the time since it (2 s at most, 0.5 s at least).
    private var streamStartNs: UInt64?
    private var lastFrame: UInt32?
    private var lastAudio: UInt32?
    /// A key frame has decoded in this session (`keys` counts the ones after it).
    private var keySeen = false
    private var delays: [Double] = []
    private var displayDelays: [Double] = []
    private var shownAt: [UInt64] = []
    private var pongs: [(rtt: UInt64, offset: Int64)] = []
    private var rtts: [UInt64] = []
    /// The newest pongs' arrival times and round trips (a ring of 16).
    private var recentRtts = [(at: UInt64, rtt: UInt64)](repeating: (0, 0), count: 16)
    private var recentNext = 0
    /// Since `takeMaxima`: the largest video-datagram interval and round trip (ns); the newest video datagram's time.
    private var netGapMaxNs: UInt64?, rttMaxNs: UInt64?
    private var lastVideoDatagramNs: UInt64?
    /// Median of `rtts`; nil before the first pong.
    private(set) var medianRttNs: UInt64?
    /// Completed frames of the last 2 s: payload size and the gap since the frame before (nil for the first).
    private var arrivals: [(at: UInt64, bytes: Int, gapMs: Double?)] = []
    private var lastArrivalNs: UInt64?
    /// Host clock minus ours (ns); nil before the first pong.
    var clockOffsetNs: Int64? { synced ? stats.clockOffsetNs : nil }

    /// No delay sample before the first pong: the clocks differ until the offset is known.
    private var synced: Bool { !pongs.isEmpty }

    /// More than this between consecutive capture times is a frame the Mac did not send (1.5 periods of `maxFps`).
    private let sourceGapNs: UInt64
    /// Capture times of the last 2 s (by the newest), and the first of this stream.
    private var captures: [UInt64] = []
    private var firstCaptureNs: UInt64?
    private var lastCaptureNs: UInt64?

    init(startNs: UInt64, maxFps: Int = 60) {
        self.startNs = startNs
        sourceGapNs = 1_500_000_000 / UInt64(max(1, maxFps))
    }

    /// A video datagram came off the socket at `nowNs` (before assembly, decode and the main queue).
    mutating func videoDatagram(nowNs: UInt64) {
        if let last = lastVideoDatagramNs, nowNs >= last { netGapMaxNs = max(netGapMaxNs ?? 0, nowNs - last) }
        lastVideoDatagramNs = nowNs
    }

    /// The largest values since the previous call; resets them. The interval across the call is kept.
    mutating func takeMaxima() -> SecondMaxima {
        defer { netGapMaxNs = nil; rttMaxNs = nil }
        return SecondMaxima(netGapMaxMs: netGapMaxNs.map { Double($0) / 1e6 }, rttMaxMs: rttMaxNs.map { Double($0) / 1e6 })
    }

    mutating func pong(sendNs: UInt64, receiveNs: UInt64, hostNs: UInt64) {
        guard receiveNs >= sendNs else { return }
        rttMaxNs = max(rttMaxNs ?? 0, receiveNs - sendNs)
        let offset = Int64(bitPattern: hostNs) &- Int64(bitPattern: sendNs / 2 &+ receiveNs / 2)
        pongs.append((receiveNs - sendNs, offset))
        if pongs.count > Self.pongWindow { pongs.removeFirst() }
        rtts.append(receiveNs - sendNs)
        if rtts.count > Self.rttWindow { rtts.removeFirst() }
        medianRttNs = rtts.sorted()[rtts.count / 2]
        recentRtts[recentNext] = (receiveNs, receiveNs - sendNs)
        recentNext = (recentNext + 1) % recentRtts.count
        stats.clockOffsetNs = pongs.min { $0.rtt < $1.rtt }?.offset ?? 0
    }

    /// The lowest round trip of the pongs that arrived in the last 300 ms, nil under 2 of them. A gap of over 150 ms
    /// between arrivals (from the newest arrival before the window, else the window's start) is a pause: the pongs sent
    /// before its end measured the pause, not a queue, and are not used. A queue delays pongs but keeps their cadence.
    func rttFloorNs(nowNs now: UInt64) -> UInt64? {
        let start = now >= Self.rttFloorNs ? now - Self.rttFloorNs : 0
        let known = recentRtts.filter { $0.at != 0 && $0.at <= now }.sorted { $0.at < $1.at }
        var previous = known.last { $0.at < start }?.at ?? start
        var cutoff: UInt64 = 0
        for e in known where e.at >= start {
            if e.at - min(previous, e.at) > Self.rttCadenceGapNs { cutoff = e.at }
            previous = e.at
        }
        var n = 0, low = UInt64.max
        for e in known where e.at >= start && e.at - e.rtt >= cutoff { n += 1; low = min(low, e.rtt) }
        return n >= Self.rttFloorMinPongs ? low : nil
    }

    mutating func frameShown(_ f: AssembledFrame, arrivalNs: UInt64) {
        stats.framesShown += 1
        if streamStartNs == nil { streamStartNs = arrivalNs }
        if let last = lastFrame, f.frame > last { stats.framesSkipped += Int(f.frame - last - 1) }
        lastFrame = f.frame
        if let last = lastCaptureNs, f.captureNs > last, f.captureNs - last > sourceGapNs { stats.sourceGaps += 1 }
        if lastCaptureNs.map({ f.captureNs > $0 }) ?? true { lastCaptureNs = f.captureNs }  // only forward
        if firstCaptureNs == nil { firstCaptureNs = f.captureNs }
        captures.append(f.captureNs)
        if let newest = lastCaptureNs { captures.removeAll { newest > $0 && newest - $0 > Self.fpsWindowNs } }
        shownAt.append(arrivalNs)
        shownAt.removeAll { arrivalNs > $0 && arrivalNs - $0 > Self.fpsWindowNs }
        var gap: Double?
        if let last = lastArrivalNs, arrivalNs >= last { gap = Double(arrivalNs - last) / 1e6 }
        lastArrivalNs = arrivalNs
        arrivals.append((arrivalNs, f.data.count, gap))
        arrivals.removeAll { arrivalNs > $0.at && arrivalNs - $0.at > Self.fpsWindowNs }
        if f.key { stats.width = Int(f.width); stats.height = Int(f.height) }
        guard synced else { return }
        let delay = Int64(bitPattern: arrivalNs) &+ stats.clockOffsetNs &- Int64(bitPattern: f.captureNs)
        delays.append(Double(delay) / 1e6)
        if delays.count > Self.delayWindow { delays.removeFirst() }
    }

    /// A new stream numbers from 0 again: the next frame starts the gap count afresh.
    mutating func videoRestarted() {
        lastFrame = nil; lastArrivalNs = nil; streamStartNs = nil
        lastCaptureNs = nil; firstCaptureNs = nil; captures.removeAll()
        shownAt.removeAll(); arrivals.removeAll()
    }

    /// Entries kept for the frame rate (internal, for the tests).
    var shownCount: Int { shownAt.count }

    /// The frame went to the display at local `nowNs`; same clock offset as the arrival delay.
    mutating func displayed(captureNs: UInt64, nowNs: UInt64) {
        stats.framesDisplayed += 1
        guard synced else { return }
        let delay = Int64(bitPattern: nowNs) &+ stats.clockOffsetNs &- Int64(bitPattern: captureNs)
        displayDelays.append(Double(delay) / 1e6)
        if displayDelays.count > Self.delayWindow { displayDelays.removeFirst() }
    }

    /// True when `seq` is newer than every block delivered so far.
    mutating func audioArrived(seq: UInt32) -> Bool {
        if let last = lastAudio {
            guard seq > last else { return false }
            stats.audioLost += Int(seq - last - 1)
        }
        lastAudio = seq
        return true
    }

    mutating func keyRequestSent() { stats.keyRequests += 1 }
    mutating func repairSent() { stats.repairRequests += 1 }
    mutating func escalated() { stats.escalations += 1 }
    mutating func ackSent() { stats.acksSent += 1 }
    mutating func decodeFailed() { stats.decodeErrors += 1 }
    /// A key frame decoded; the first of the session is not counted in `keys`.
    mutating func keyDecoded() { if keySeen { stats.keys += 1 }; keySeen = true }

    mutating func hostStats(_ h: HostStats) { stats.host = h }
    mutating func load(_ l: HostLoad, atNs: UInt64) { stats.load = l; stats.loadAtNs = atNs }

    /// The assembler's totals (it is made afresh with each video stream, so they restart with it).
    mutating func repairCounts(_ c: AssemblerCounts) {
        stats.nacksSent = c.nacksSent; stats.fragmentsAsked = c.fragmentsAsked
        stats.fragmentsRecovered = c.fragmentsRecovered; stats.framesRepaired = c.framesRepaired
        stats.framesGivenUp = c.framesGivenUp; stats.refreshes = c.restartsAtRepair; stats.fragmentsLate = c.fragmentsLate
        stats.restartsAsked = c.refreshes; stats.framesWaited = c.framesWaited
    }

    mutating func snapshot(nowNs: UInt64) -> SessionStats {
        shownAt.removeAll { nowNs > $0 && nowNs - $0 > Self.fpsWindowNs }
        let span = streamStartNs.map { nowNs > $0 ? Double(nowNs - $0) / 1e9 : 0 } ?? 0
        let elapsed = span > 0 ? min(max(span, 0.5), 2) : 0
        stats.fps = elapsed > 0 ? Double(shownAt.count) / elapsed : 0
        if let first = firstCaptureNs, let newest = lastCaptureNs {
            let captureSpan = min(max(newest > first ? Double(newest - first) / 1e9 : 0, 0.5), 2)
            stats.sourceFps = Double(captures.count) / captureSpan
        } else {
            stats.sourceFps = 0
        }
        stats.p95DelayMs = Self.p95(delays)
        stats.p95DisplayMs = Self.p95(displayDelays)
        stats.p50DisplayMs = Self.median(displayDelays)
        stats.rttMs = Self.median(rtts.map { Double($0) / 1e6 })
        stats.rttFloorMs = rttFloorNs(nowNs: nowNs).map { Double($0) / 1e6 }
        arrivals.removeAll { nowNs > $0.at && nowNs - $0.at > Self.fpsWindowNs }
        stats.bitrateMbps = elapsed > 0 ? Double(arrivals.reduce(0) { $0 + $1.bytes }) * 8 / elapsed / 1e6 : 0
        let gaps = arrivals.compactMap(\.gapMs)
        stats.p95ArrivalGapMs = Self.p95(gaps)
        stats.maxArrivalGapMs = gaps.max() ?? 0
        return stats
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func p95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
    }
}

extension SessionStats {
    /// The tool's last line: `frames=<n> fps=<x> p95_ms=<x> skipped=<n> audio_lost=<n> given_up=<n> asked=<n> recovered=<n>
    /// repairs=<n> repair_frames=<n> escalations=<n> keys=<n> decode_errors=<n> acks=<n> max_gap_ms=<n> rate_mbps=<start>/<low>/<end>
    /// cuts=<n>` -> .claude/client.md § fakeclient. `longestGapMs`: the longest time between pictures over the run (the
    /// tool keeps it; `maxArrivalGapMs` is the last 2 s). `runFps`: the tool's rate over the run (pictures between the
    /// first and the last); none: the last 2 s's `fps`, which reads 0 once the game has left. Rates: the session's own (`rateStartBps`, `rateLowBps`, now); a run
    /// with none (no change, or a fixed rate) shows the rate in force, the Host's applied one, in all three.
    public func runLine(longestGapMs: Double, runFps: Double? = nil) -> String {
        func mbps(_ bps: UInt32) -> String { String(format: "%.1f", Double(bps) / 1e6) }
        let now = rateBps != 0 ? rateBps : (host?.rateBps ?? 0)
        let start = rateStartBps != 0 ? rateStartBps : now
        let low = rateLowBps != 0 ? min(rateLowBps, now == 0 ? rateLowBps : now) : now
        return String(format: "frames=%d fps=%.1f p95_ms=%.1f skipped=%d audio_lost=%d", framesShown, runFps ?? fps, p95DelayMs, framesSkipped, audioLost)
            + " given_up=\(framesGivenUp) asked=\(fragmentsAsked) recovered=\(fragmentsRecovered) repairs=\(repairRequests)"
            + " repair_frames=\(refreshes) escalations=\(escalations) keys=\(keys) decode_errors=\(decodeErrors) acks=\(acksSent)"
            + String(format: " max_gap_ms=%.0f", longestGapMs)
            + " rate_mbps=\(mbps(start))/\(mbps(low))/\(mbps(now)) cuts=\(rateCuts)"
    }
}
