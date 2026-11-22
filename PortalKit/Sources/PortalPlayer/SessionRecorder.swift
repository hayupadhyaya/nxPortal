import Foundation
import PortalClientCore
import PortalKit

/// The picture-arrival numbers of one window (about a second), measured in the view -> .claude/client.md § recorder
public struct PhaseSummary: Equatable, Sendable {
    public var arrivals = 0
    /// Arrival time minus the previous display refresh's time, ms; nil when no refresh was known yet.
    public var phaseMeanMs: Double?, phaseMinMs: Double?, phaseMaxMs: Double?
    /// Time between consecutive arrivals, ms; nil under two arrivals.
    public var intervalMeanMs: Double?, intervalP95Ms: Double?, intervalMaxMs: Double?
    /// The interval the display link reported for its last refresh, ms.
    public var refreshMs: Double?
}

/// Pure bookkeeping: `refresh` once per display refresh, `arrival` once per picture, `take` once a window. It only
/// reads times it is given: nothing here touches the pacer or what is shown.
public struct ArrivalMeter: Sendable {
    private var lastRefreshNs: UInt64?
    private var lastArrivalNs: UInt64?
    private var refreshMs: Double?
    private var phases: [Double] = []
    private var intervals: [Double] = []
    private var arrivals = 0

    public init() {}

    /// A display refresh at `atNs` (the display link's own timestamp, on the `uptimeNs()` clock) whose period is `intervalMs`.
    public mutating func refresh(atNs: UInt64, intervalMs: Double) {
        lastRefreshNs = atNs
        if intervalMs > 0, intervalMs.isFinite { refreshMs = intervalMs }
    }

    public mutating func arrival(atNs: UInt64) {
        arrivals += 1
        if let r = lastRefreshNs, atNs >= r { phases.append(Double(atNs - r) / 1e6) }
        if let last = lastArrivalNs, atNs >= last { intervals.append(Double(atNs - last) / 1e6) }
        lastArrivalNs = atNs
    }

    /// The window's numbers and a fresh window; nil when no picture arrived in it. The interval across the take is kept.
    public mutating func take() -> PhaseSummary? {
        defer { phases.removeAll(keepingCapacity: true); intervals.removeAll(keepingCapacity: true); arrivals = 0 }
        guard arrivals > 0 else { return nil }
        var s = PhaseSummary(arrivals: arrivals, refreshMs: refreshMs)
        if !phases.isEmpty {
            s.phaseMeanMs = phases.reduce(0, +) / Double(phases.count)
            s.phaseMinMs = phases.min(); s.phaseMaxMs = phases.max()
        }
        if !intervals.isEmpty {
            let sorted = intervals.sorted()
            s.intervalMeanMs = intervals.reduce(0, +) / Double(intervals.count)
            s.intervalP95Ms = sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
            s.intervalMaxMs = sorted.last
        }
        return s
    }

    /// The display link was paused: the next arrivals have no previous refresh to be measured against.
    public mutating func linkPaused() { lastRefreshNs = nil }

    public mutating func reset() { self = ArrivalMeter() }
}

/// What the view reports once a window: the pacer's counts and queue, and the arrival numbers.
public struct DisplayReport: Equatable, Sendable {
    public var shown = 0, late = 0, empty = 0, pending = 0
    public var phase: PhaseSummary?
    public init() {}
}

/// One second's line: `key=value` pairs in the order they were put; unknown values are left out.
public struct SessionSample: Equatable, Sendable {
    private var pairs: [String] = []
    public init() {}

    public mutating func put(_ key: String, _ value: Double?, digits: Int = 0) {
        guard let value, value.isFinite, abs(value) < 1e15 else { return }
        pairs.append("\(key)=" + (digits == 0 ? String(Int(value.rounded())) : String(format: "%.\(digits)f", value)))
    }
    public mutating func put(_ key: String, _ value: Int?) { if let value { pairs.append("\(key)=\(value)") } }
    public mutating func put(_ key: String, _ word: String?) { if let word { pairs.append("\(key)=\(word)") } }

    public var line: String { pairs.joined(separator: " ") }

    /// The fixed order of the line -> .claude/client.md § recorder
    public static func make(seconds: Double, stats s: SessionStats, play: ClientModel.PlayStats, display: DisplayReport?,
                            soundLevelMs: Int?, decode: (meanMs: Double, maxMs: Double)?, thermal: Int, lowPower: Bool,
                            maxima: SecondMaxima = SecondMaxima()) -> SessionSample {
        var o = SessionSample()
        o.put("t_s", seconds)
        if let d = display {
            o.put("arrived", d.phase?.arrivals ?? 0)
            o.put("shown", d.shown); o.put("late", d.late); o.put("empty", d.empty)
            o.put("queue", d.pending); o.put("queue_target", FramePacer<Int>.target)
            if let p = d.phase {
                o.put("phase_mean_ms", p.phaseMeanMs, digits: 1); o.put("phase_min_ms", p.phaseMinMs, digits: 1)
                o.put("phase_max_ms", p.phaseMaxMs, digits: 1); o.put("refresh_ms", p.refreshMs, digits: 2)
                o.put("gap_mean_ms", p.intervalMeanMs, digits: 1); o.put("gap_p95_ms", p.intervalP95Ms, digits: 1)
                o.put("gap_max_ms", p.intervalMaxMs, digits: 1)
            }
        }
        o.put("mac_fps", s.fps, digits: 1); o.put("source_gaps", s.sourceGaps)
        o.put("width", s.width > 0 ? s.width : nil); o.put("height", s.height > 0 ? s.height : nil)
        o.put("mbit", s.bitrateMbps, digits: 1)
        o.put("delay_p50_ms", s.p50DisplayMs, digits: 1); o.put("delay_p95_ms", s.p95DisplayMs, digits: 1)
        if let d = decode { o.put("decode_mean_ms", d.meanMs, digits: 1); o.put("decode_max_ms", d.maxMs, digits: 1) }
        o.put("skipped", s.framesSkipped)
        o.put("rate_mbps", Double(s.host?.rateBps ?? s.rateBps) / 1e6, digits: 1)
        o.put("rate_ceiling_mbps", Double(s.rateCeilingBps) / 1e6, digits: 1)
        o.put("rate_cuts", s.rateCuts)
        o.put("rate_why", s.rateChanges.last?.why.rawValue)
        o.put("rtt_floor_ms", s.rttFloorMs, digits: 1)
        o.put("rtt_ms", s.rttMs > 0 ? s.rttMs : nil, digits: 1)
        o.put("asked", s.fragmentsAsked); o.put("recovered", s.fragmentsRecovered); o.put("given_up", s.framesGivenUp)
        o.put("key_requests", s.keyRequests); o.put("refreshes", s.refreshes)
        o.put("sound_target_ms", play.soundBufferMs); o.put("sound_level_ms", soundLevelMs)
        o.put("underruns", play.soundUnderruns); o.put("blocks_lost", play.soundLost)
        if let h = s.host {
            o.put("host_from_game", Int(h.framesFromGame)); o.put("host_sent", Int(h.framesSent))
            o.put("host_dropped", Int(h.framesDropped)); o.put("host_resent", Int(h.resent))
            o.put("host_rate_mbps", Double(h.rateBps) / 1e6, digits: 1); o.put("host_late_us", Int(h.sendLateMaxUs))
        }
        o.put("thermal", thermal); o.put("low_power", lowPower ? 1 : 0)
        o.put("net_gap_max_ms", maxima.netGapMaxMs, digits: 1); o.put("rtt_max_ms", maxima.rttMaxMs, digits: 1)
        o.put("repair_requests", s.repairRequests); o.put("escalations", s.escalations); o.put("keys", s.keys)
        o.put("frames_repaired", s.framesRepaired); o.put("decode_errors", s.decodeErrors)
        return o
    }
}

/// The first line of a file: the build, the device and the session's settings; nothing personal.
public struct SessionHeader: Equatable, Sendable {
    public var app: String, build: String, os: String, platform: String, model: String
    public var displayMaxHz: Int?
    public var titleID: String?
    public var width: Int, height: Int, fpsCap: Int, bitrateMbps: Int
    public var smooth: Bool
    public var soundBuffer: String

    public init(app: String, build: String, os: String, platform: String, model: String, displayMaxHz: Int?, titleID: String?,
                width: Int, height: Int, fpsCap: Int, bitrateMbps: Int, smooth: Bool, soundBuffer: String) {
        self.app = app; self.build = build; self.os = os; self.platform = platform; self.model = model
        self.displayMaxHz = displayMaxHz; self.titleID = titleID; self.width = width; self.height = height
        self.fpsCap = fpsCap; self.bitrateMbps = bitrateMbps; self.smooth = smooth; self.soundBuffer = soundBuffer
    }

    public var line: String {
        var s = "session v=1 app=\(app) build=\(build) platform=\(platform) os=\(os) model=\(model)"
        if let hz = displayMaxHz { s += " display_max_hz=\(hz)" }
        if let t = titleID { s += " title=\(t)" }
        return s + " size=\(width)x\(height) fps_cap=\(fpsCap) bitrate_cap_mbps=\(bitrateMbps) smooth=\(smooth ? 1 : 0) sound_buffer=\(soundBuffer)"
    }
}

public struct LogFile: Equatable, Sendable {
    public var name: String, bytes: Int, modified: Date
    public init(name: String, bytes: Int, modified: Date) { self.name = name; self.bytes = bytes; self.modified = modified }
}

public enum SessionLogs {
    public static let maxFiles = 30, maxBytes = 20_000_000

    /// Names to delete: newest first, files are kept while at most `maxFiles` and `maxBytes` hold; from the first one
    /// that does not fit, every older one goes too (oldest first is the order of removal).
    public static func removals(_ files: [LogFile]) -> [String] {
        let newestFirst = files.sorted { ($0.modified, $0.name) > ($1.modified, $1.name) }
        var kept = 0, total = 0, cut = false
        var gone: [String] = []
        for f in newestFirst {
            if !cut, kept < maxFiles, total + f.bytes <= maxBytes { kept += 1; total += f.bytes } else { cut = true; gone.append(f.name) }
        }
        return gone.reversed()
    }
}

/// Appends a session's lines to `<directory>/<UTC yyyyMMdd-HHmmss>.log`. A failed write turns it off for the session
/// and is counted; nothing is thrown at the caller. All file work happens on this actor, never on the main actor.
public actor SessionRecorder {
    private let directory: URL
    private var handle: FileHandle?
    public private(set) var isOn = false
    public private(set) var failures = 0

    public init(directory: URL) { self.directory = directory }

    public func begin(header: String, now: Date = Date()) {
        end()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss"
            let stem = f.string(from: now)
            var url = directory.appendingPathComponent(stem + ".log"), n = 1
            while fm.fileExists(atPath: url.path) { url = directory.appendingPathComponent("\(stem)-\(n).log"); n += 1 }
            guard fm.createFile(atPath: url.path, contents: Data((header + "\n").utf8)) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
            isOn = true
            prune()
        } catch { fail() }
    }

    public func append(_ line: String) {
        guard isOn, let handle else { return }
        do { try handle.write(contentsOf: Data((line + "\n").utf8)) } catch { fail() }
    }

    public func end() {
        try? handle?.close()
        handle = nil
        isOn = false
    }

    private func fail() { failures += 1; end() }

    private func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        // Only files this recorder names (and wrote): `yyyyMMdd-HHmmss[-n].log`, regular files.
        let files: [LogFile] = urls.filter { $0.lastPathComponent.range(of: #"^\d{8}-\d{6}(-\d+)?\.log$"#, options: .regularExpression) != nil }.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys + [.isRegularFileKey])), v.isRegularFile == true else { return nil }
            return LogFile(name: u.lastPathComponent, bytes: v.fileSize ?? 0, modified: v.contentModificationDate ?? .distantPast)
        }
        for name in SessionLogs.removals(files) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }
}
