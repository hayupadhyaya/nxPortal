import Foundation

/// The sound buffer the link asks for, from the gaps between sound datagram arrivals; pure, time is an argument
/// -> .claude/client.md § sound
public struct SoundBufferTarget: Sendable {
    public static let startMs = 50, minMs = 20, maxMs = 100
    static let marginMs = 10.0, raiseMs = 10.0, downMsPerSecond = 5.0
    static let windowNs: UInt64 = 5_000_000_000, raiseHoldNs: UInt64 = 30_000_000_000
    static let maxGapNs: UInt64 = 500_000_000, warmupNs: UInt64 = 1_000_000_000
    /// The percentile is recomputed at most this often (a sort of the window).
    static let refreshNs: UInt64 = 50_000_000
    static let capacity = 4096
    /// The rare-gap window: the two largest gaps of each of the last 31 seconds (the second-largest overall is among them).
    static let longWindowSeconds = 30, rareMarginMs = 5.0
    static let restartExemptNs: UInt64 = 1_000_000_000

    /// The last `windowNs` of gaps: arrival time and length in microseconds; a ring sized once.
    private var times = [UInt64](repeating: 0, count: SoundBufferTarget.capacity)
    private var gaps = [UInt32](repeating: 0, count: SoundBufferTarget.capacity)
    private var scratch = [UInt32](repeating: 0, count: SoundBufferTarget.capacity)
    private var head = 0, count = 0
    /// One bucket per second (`second % 32`): the two largest gaps, microseconds, and the second they belong to.
    private struct Bucket { var second = UInt64.max; var top1: UInt32 = 0, top2: UInt32 = 0 }
    private var buckets = [Bucket](repeating: Bucket(), count: 32)
    /// Arrivals before this are a restart's: an underrun then is the pause's own and adds nothing.
    private var restartedAtNs: UInt64?
    private var lastArrivalNs: UInt64?
    private var firstArrivalNs: UInt64?
    private var raises = 0
    private var raiseEndNs: UInt64 = 0
    private var measuredMs: Double?
    private var measuredAtNs: UInt64 = 0
    /// The wanted value after the down-slew; nil until a measurement exists (the start value is not slewed).
    private var current: Double?
    private var currentAtNs: UInt64 = 0

    public init() {}

    /// A sound datagram arrived (a repeat of a block already in is not an arrival). A gap over 500 ms (a pause, a stall, the
    /// start) is not a measurement and starts over: both windows emptied, the 1 s warm-up again.
    public mutating func arrival(atNs now: UInt64) {
        if firstArrivalNs == nil { firstArrivalNs = now }
        defer { lastArrivalNs = now }
        guard let last = lastArrivalNs, now >= last else { return }
        let gap = now - last
        guard gap <= Self.maxGapNs else { return restart(atNs: now) }
        let slot = (head + count) % Self.capacity
        times[slot] = now
        gaps[slot] = UInt32(gap / 1000)
        if count < Self.capacity { count += 1 } else { head = (head + 1) % Self.capacity }
        let us = UInt32(gap / 1000), sec = now / 1_000_000_000
        var b = buckets[Int(sec % 32)]
        if b.second != sec { b = Bucket(second: sec) }
        if us > b.top1 { b.top2 = b.top1; b.top1 = us } else if us > b.top2 { b.top2 = us }
        buckets[Int(sec % 32)] = b
    }

    private mutating func restart(atNs now: UInt64) {
        head = 0; count = 0
        for i in 0..<buckets.count { buckets[i] = Bucket() }
        firstArrivalNs = now
        restartedAtNs = now
        measuredMs = nil
        current = nil
        raises = 0
        raiseEndNs = 0
    }

    /// The output starved: +10 ms at once, held 30 s from the newest underrun, then it leaves through the down-slew.
    public mutating func underrun(atNs now: UInt64) {
        // The pause's own starvation (seen at the first push after it, before or after its arrival) is not the link's.
        if let last = lastArrivalNs, now > last, now - last > Self.maxGapNs { return }
        if let r = restartedAtNs, now >= r, now - r <= Self.restartExemptNs { return }
        if now >= raiseEndNs { raises = 0 }
        raises += 1
        raiseEndNs = now + Self.raiseHoldNs
    }

    /// The buffer wanted now, ms (20...100): up at once, down at most 5 ms a second.
    public mutating func wantedMs(atNs now: UInt64) -> Int {
        if now >= raiseEndNs { raises = 0 }
        guard let first = firstArrivalNs, let last = lastArrivalNs, last >= first + Self.warmupNs, let m = measured(atNs: now) else {
            return Self.startMs
        }
        var wide = m + Self.marginMs
        wide = max(wide, secondLargestGapMs(atNs: now) + Self.rareMarginMs)
        let base = min(Double(Self.maxMs), max(Double(Self.minMs), wide))
        let wanted = min(Double(Self.maxMs), base + Self.raiseMs * Double(raises))
        if let c = current, wanted < c {
            let dt = Double(now > currentAtNs ? now - currentAtNs : 0) / 1e9
            current = max(wanted, c - Self.downMsPerSecond * dt)
        } else {
            current = wanted
        }
        currentAtNs = now
        return Int(current!.rounded())
    }

    /// The second-largest gap of the last 30 s, ms (0 with fewer than two gaps: one outlier alone is not seen).
    private func secondLargestGapMs(atNs now: UInt64) -> Double {
        let sec = now / 1_000_000_000
        var first: UInt32 = 0, second: UInt32 = 0
        for b in buckets where b.second != UInt64.max && b.second <= sec && sec - b.second <= UInt64(Self.longWindowSeconds) {
            if b.top1 > first { second = first; first = b.top1 } else if b.top1 > second { second = b.top1 }
            if b.top2 > first { second = first; first = b.top2 } else if b.top2 > second { second = b.top2 }
        }
        return Double(second) / 1000
    }

    /// The 99th percentile of the gaps of the last 5 s, ms; nil when the window holds none.
    private mutating func measured(atNs now: UInt64) -> Double? {
        if let m = measuredMs, now >= measuredAtNs, now - measuredAtNs < Self.refreshNs { return m }
        while count > 0, now > times[head], now - times[head] > Self.windowNs { head = (head + 1) % Self.capacity; count -= 1 }
        measuredAtNs = now
        guard count > 0 else { measuredMs = nil; return nil }
        for i in 0..<count { scratch[i] = gaps[(head + i) % Self.capacity] }
        let n = count
        scratch.withUnsafeMutableBufferPointer { $0[0..<n].sort() }
        let rank = Int((0.99 * Double(n)).rounded(.up)) - 1
        let m = Double(scratch[min(n - 1, max(0, rank))]) / 1000
        measuredMs = m
        return m
    }
}
