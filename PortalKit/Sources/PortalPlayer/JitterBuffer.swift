import Foundation

/// Sound blocks to a steady stream of 48 kHz stereo frames; pure, no clock -> .claude/client.md § sound
public struct JitterBuffer: Sendable {
    public static let fadeFrames = 48
    /// Frames in one 960-byte block.
    static let blockFrames = 240

    public private(set) var targetFrames: Int
    public let maxFrames: Int
    public private(set) var bufferedFrames = 0
    public private(set) var underruns = 0
    public private(set) var lostBlocks = 0

    /// Ring of interleaved samples, sized once so `pull` never allocates.
    private var ring: [Int16]
    private var head = 0                // first stored sample
    private var filling = true
    private var rampedIn = 0            // frames played since filling ended, capped at fadeFrames
    private var lastSeq: UInt32?

    public init(targetFrames: Int = 1200, maxFrames: Int = 4800) {
        self.targetFrames = max(0, targetFrames)
        self.maxFrames = max(maxFrames, targetFrames, Self.blockFrames)
        ring = [Int16](repeating: 0, count: (self.maxFrames + Self.blockFrames) * 2)
    }

    private func slot(_ frame: Int) -> Int { (head + frame * 2) % ring.count }

    /// Scales both samples of stored frame `frame` by `num / den`.
    private mutating func scale(frame: Int, _ num: Int, _ den: Int) {
        for c in 0..<2 {
            let i = (slot(frame) + c) % ring.count
            ring[i] = Int16(Int(ring[i]) * num / den)
        }
    }

    private mutating func rampDownTail() {
        let n = Self.fadeFrames
        guard bufferedFrames >= n else { return }
        for i in 0..<n { scale(frame: bufferedFrames - n + i, n - 1 - i, n) }
    }

    private mutating func rampUp(from frame: Int) {
        for i in 0..<Self.fadeFrames { scale(frame: frame + i, i, Self.fadeFrames) }
    }

    /// Back to the initial state: empty, filling, no last `seq`, counters zero.
    public mutating func reset() {
        head = 0; bufferedFrames = 0; filling = true; rampedIn = 0; lastSeq = nil
        underruns = 0; lostBlocks = 0
    }

    /// Drops what is buffered and starts filling again; any `seq` is accepted next; the counters stay.
    public mutating func flush() {
        head = 0; bufferedFrames = 0; filling = true; rampedIn = 0; lastSeq = nil
    }

    /// Changes the target while playing, under the caller's lock. Raised: nothing changes now, the next refill waits for
    /// it. Lowered: while over the new target by more than a block, the oldest frames are dropped, as many as the change
    /// asked (never the whole surplus: a burst's cushion stays), the new head fades in.
    public mutating func setTarget(frames: Int) {
        let new = min(max(0, frames), maxFrames)
        let old = targetFrames
        targetFrames = new
        guard new < old, !filling, bufferedFrames > new + Self.blockFrames else { return }
        let drop = min(old - new, bufferedFrames - new)
        head = (head + drop * 2) % ring.count
        bufferedFrames -= drop
        rampUp(from: 0)
    }

    /// Returns false for a block that is not taken: a wrong size, or a `seq` at or below the last (a repeat).
    @discardableResult
    public mutating func push(seq: UInt32, pcm: Data) -> Bool {
        guard pcm.count == Self.blockFrames * 4 else { return false }
        var gap = false
        if let last = lastSeq {
            guard seq > last else { return false }
            if seq > last + 1 { gap = true; lostBlocks += Int(seq - last - 1) }
        }
        lastSeq = seq
        if gap { rampDownTail() }
        let start = bufferedFrames
        pcm.withUnsafeBytes { raw in
            for s in 0..<(Self.blockFrames * 2) {
                let v = UInt16(raw[2 * s]) | UInt16(raw[2 * s + 1]) << 8
                ring[(head + (start * 2) + s) % ring.count] = Int16(bitPattern: v)
            }
        }
        bufferedFrames += Self.blockFrames
        if gap { rampUp(from: start) }
        if bufferedFrames > maxFrames {
            let drop = bufferedFrames - targetFrames
            head = (head + drop * 2) % ring.count
            bufferedFrames = targetFrames
            if !filling { rampUp(from: 0) }
        }
        if filling && bufferedFrames >= targetFrames { filling = false; rampedIn = 0 }
        return true
    }

    /// Writes `frames` interleaved stereo frames (2 * frames samples).
    public mutating func pull(frames: Int, into out: UnsafeMutablePointer<Int16>) {
        guard frames > 0 else { return }
        let fade = Self.fadeFrames
        if filling {
            out.update(repeating: 0, count: frames * 2)
            return
        }
        let avail = min(frames, bufferedFrames)
        for f in 0..<avail {
            let k = rampedIn + f
            for c in 0..<2 {
                let v = Int(ring[(head + f * 2 + c) % ring.count])
                out[f * 2 + c] = Int16(k < fade ? v * k / fade : v)
            }
        }
        head = (head + avail * 2) % ring.count
        bufferedFrames -= avail
        rampedIn = min(fade, rampedIn + avail)
        guard avail < frames else { return }
        let k = min(fade, avail)
        for i in 0..<k {
            let f = avail - k + i
            for c in 0..<2 { out[f * 2 + c] = Int16(Int(out[f * 2 + c]) * (k - 1 - i) / k) }
        }
        out.advanced(by: avail * 2).update(repeating: 0, count: (frames - avail) * 2)
        underruns += 1
        filling = true
        rampedIn = 0
    }
}
