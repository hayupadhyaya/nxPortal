import XCTest
@testable import PortalPlayer

final class JitterBufferTests: XCTestCase {
    private static let blockFrames = 240

    /// One block: 240 stereo frames, both channels `value`, 16-bit little-endian.
    private func block(_ value: Int16 = 1000) -> Data {
        var data = Data(capacity: Self.blockFrames * 4)
        let le = UInt16(bitPattern: value).littleEndian
        for _ in 0..<(Self.blockFrames * 2) { withUnsafeBytes(of: le) { data.append(contentsOf: $0) } }
        return data
    }

    /// Pulls `frames`; returns the left channel and asserts both channels equal.
    private func pull(_ buffer: inout JitterBuffer, _ frames: Int, file: StaticString = #filePath, line: UInt = #line) -> [Int16] {
        var out = [Int16](repeating: 77, count: frames * 2)
        out.withUnsafeMutableBufferPointer { buffer.pull(frames: frames, into: $0.baseAddress!) }
        var left = [Int16]()
        for f in 0..<frames {
            XCTAssertEqual(out[2 * f], out[2 * f + 1], "channels differ at frame \(f)", file: file, line: line)
            left.append(out[2 * f])
        }
        return left
    }

    private func assertRising(_ s: ArraySlice<Int16>, file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(s, s.dropFirst()) { XCTAssertLessThan(a, b, file: file, line: line) }
    }

    func testSilentUntilTarget() {
        var b = JitterBuffer()
        for seq in 1...4 { b.push(seq: UInt32(seq), pcm: block()) }
        XCTAssertEqual(pull(&b, 240), [Int16](repeating: 0, count: 240))
        XCTAssertEqual(b.underruns, 0)
        b.push(seq: 5, pcm: block())
        let s = pull(&b, 240)
        XCTAssertEqual(s[0], 0)
        assertRising(s[0..<48])
        XCTAssertTrue(s[48...].allSatisfy { $0 == 1000 })
    }

    func testUnderrunFadesAndRefills() {
        var b = JitterBuffer()
        for seq in 1...5 { b.push(seq: UInt32(seq), pcm: block()) }
        let s = pull(&b, 1440)
        assertRising(s[0..<48])
        for (a, c) in zip(s[1152..<1200], s[1153..<1200]) { XCTAssertGreaterThan(a, c) }
        XCTAssertEqual(s[1199], 0)
        XCTAssertTrue(s[1200...].allSatisfy { $0 == 0 })
        XCTAssertEqual(b.underruns, 1)
        XCTAssertEqual(pull(&b, 240), [Int16](repeating: 0, count: 240))
    }

    func testGapCountsAndFades() {
        var b = JitterBuffer()
        for seq in 1...5 { b.push(seq: UInt32(seq), pcm: block()) }
        b.push(seq: 8, pcm: block())
        XCTAssertEqual(b.lostBlocks, 2)
        XCTAssertEqual(b.bufferedFrames, 1440)
        let s = pull(&b, 1440)
        XCTAssertEqual(Double(s[1199]), 0, accuracy: 25)
        XCTAssertEqual(Double(s[1200]), 0, accuracy: 25)
        XCTAssertEqual(s[1300], 1000)
    }

    /// A stalled link: what is buffered is dropped, the next blocks fill from empty (silence, then a fade-in), any `seq`
    /// is accepted (the blocks after the stall are far ahead), and the counters stay.
    func testFlushEmptiesAndRefills() {
        var b = JitterBuffer()
        for seq in 1...5 { b.push(seq: UInt32(seq), pcm: block()) }
        _ = pull(&b, 1440)  // one underrun
        for seq in 6...10 { b.push(seq: UInt32(seq), pcm: block()) }
        b.flush()
        XCTAssertEqual(b.bufferedFrames, 0)
        XCTAssertEqual(b.underruns, 1, "the counters belong to the session")
        XCTAssertEqual(pull(&b, 240), [Int16](repeating: 0, count: 240), "the old sound looped after the flush")
        for seq in 900...903 { b.push(seq: UInt32(seq), pcm: block()) }
        XCTAssertEqual(pull(&b, 240), [Int16](repeating: 0, count: 240), "still filling")
        XCTAssertEqual(b.lostBlocks, 0, "a flush is not a gap")
        b.push(seq: 904, pcm: block())
        let s = pull(&b, 240)
        assertRising(s[0..<48])
        XCTAssertTrue(s[48...].allSatisfy { $0 == 1000 })
    }

    /// A target raised while playing changes nothing that is playing; the next refill waits for the new target.
    func testRaisedTargetWhilePlayingInsertsNoSilenceAndAppliesAtTheNextRefill() {
        var b = JitterBuffer()
        for seq in 1...5 { b.push(seq: UInt32(seq), pcm: block()) }
        _ = pull(&b, 240)                       // playing
        b.setTarget(frames: 2400)
        XCTAssertEqual(b.targetFrames, 2400)
        b.push(seq: 6, pcm: block())
        let s = pull(&b, 960)
        XCTAssertTrue(s.allSatisfy { $0 == 1000 }, "silence inserted into playing sound")
        XCTAssertEqual(b.underruns, 0)
        _ = pull(&b, 4800)                      // drain: one underrun, back to filling
        XCTAssertEqual(b.underruns, 1)
        for seq in 7...15 { b.push(seq: UInt32(seq), pcm: block()) }   // 2160 frames: under 2400
        XCTAssertEqual(pull(&b, 240), [Int16](repeating: 0, count: 240), "refilling to the new target")
        b.push(seq: 16, pcm: block())
        XCTAssertTrue(pull(&b, 240).contains(1000), "the new target is reached after the refill")
    }

    /// A lowered target trims what is over it, no more than the change asks, and fades the new head in.
    func testLoweredTargetTrimsNoFasterThanAsked() {
        var b = JitterBuffer(targetFrames: 4800, maxFrames: 7200)
        for seq in 1...20 { b.push(seq: UInt32(seq), pcm: block()) }   // fills to 4800: playing
        _ = pull(&b, 48)
        let before = b.bufferedFrames
        b.setTarget(frames: 4700)               // 100 frames lower: inside one block of slack
        XCTAssertEqual(b.bufferedFrames, before, "a small change trims nothing")
        b.setTarget(frames: 3600)               // 1100 frames lower than 4700
        XCTAssertGreaterThanOrEqual(b.bufferedFrames, 3600)
        XCTAssertLessThanOrEqual(before - b.bufferedFrames, 4800 - 3600, "trimmed more than the change asked")
        XCTAssertEqual(b.bufferedFrames, before - 1100, "exactly what the change asked")
        let s = pull(&b, 96)
        XCTAssertLessThan(abs(Int(s[0])), 100, "a click at the trim")
        assertRising(s[0..<48])
        XCTAssertEqual(b.underruns, 0)
    }

    /// The buffer sits at the top of a burst (target + 3 blocks): a 1 ms lowering drops 1 ms, not the cushion.
    func testLoweredTargetDropsOnlyWhatWasAsked() {
        var b = JitterBuffer(targetFrames: 1200, maxFrames: 4800)
        for seq in 1...8 { b.push(seq: UInt32(seq), pcm: block()) }   // playing at 1200, then up to 1920
        XCTAssertEqual(b.bufferedFrames, 1920)
        b.setTarget(frames: 1152)               // 1 ms lower
        XCTAssertEqual(b.bufferedFrames, 1872, "1 ms = 48 frames")
        let s = pull(&b, 1872)
        XCTAssertEqual(b.underruns, 0)
        XCTAssertEqual(s.count, 1872)
    }

    func testLoweredTargetWhileFillingTrimsNothing() {
        var b = JitterBuffer(targetFrames: 4800, maxFrames: 7200)
        for seq in 1...10 { b.push(seq: UInt32(seq), pcm: block()) }
        b.setTarget(frames: 1200)
        XCTAssertEqual(b.bufferedFrames, 2400)
    }

    func testARepeatIsDroppedAndCountsNothing() {
        var b = JitterBuffer()
        b.push(seq: 1, pcm: block()); b.push(seq: 2, pcm: block())
        b.push(seq: 2, pcm: block()); b.push(seq: 1, pcm: block())
        XCTAssertEqual(b.bufferedFrames, 480)
        XCTAssertEqual(b.lostBlocks, 0)
        XCTAssertEqual(b.underruns, 0)
    }

    /// Blocks at or below the last `seq` are dropped and count nothing; the blocks that arrive in order play whole, no gap counted.
    func testBlocksAtOrBelowTheLastSeqAreDroppedAndTheRestPlaysWhole() {
        var b = JitterBuffer(targetFrames: 480, maxFrames: 4800)
        let order: [UInt32] = [1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6, 7]   // duplicates are dropped, in-order blocks kept
        for seq in order { b.push(seq: seq, pcm: block(Int16(seq) * 100)) }
        XCTAssertEqual(b.lostBlocks, 0)
        let s = pull(&b, 7 * 240)
        for seq in 1...7 {
            // the middle of each block (clear of the ramp-in of the first)
            XCTAssertEqual(s[(seq - 1) * 240 + 120], Int16(seq) * 100, "block \(seq)")
        }
        XCTAssertEqual(b.underruns, 0)
    }

    func testOldSeqDropped() {
        var b = JitterBuffer()
        b.push(seq: 5, pcm: block())
        b.push(seq: 5, pcm: block())
        b.push(seq: 3, pcm: block())
        XCTAssertEqual(b.bufferedFrames, 240)
        XCTAssertEqual(b.lostBlocks, 0)
    }

    func testOverflowDropsToTarget() {
        var b = JitterBuffer()
        for seq in 1...20 { b.push(seq: UInt32(seq), pcm: block()) }
        XCTAssertEqual(b.bufferedFrames, 4800)
        b.push(seq: 21, pcm: block())
        XCTAssertEqual(b.bufferedFrames, 1200)
    }

    /// The largest offered target (100 ms) with the output's maximum: steady 240-frame pushes against 256-frame
    /// pulls, one block 5 ms early -> no overflow drop, no fade after the first ramp-in.
    func testLargestTargetHasRoom() {
        let target = 4800
        var b = JitterBuffer(targetFrames: target, maxFrames: AudioOutput.maxFrames(targetFrames: target))
        let blocks = 400, early = 100
        // Times in frames (48 per ms): block k at 240 k, block `early` 5 ms (240 frames) early; a pull every 256.
        var events: [(t: Int, push: Int?)] = (0..<blocks).map { k in (k == early ? 240 * k - 240 : 240 * k, k) }
        var t = 0
        while t < 240 * (blocks - 1) { events.append((t, nil)); t += 256 }
        // Same time: pushes in block order, then the pull.
        events.sort { ($0.t, $0.push ?? Int.max) < ($1.t, $1.push ?? Int.max) }
        var out: [Int16] = [], pushed = 0, pulled = 0
        for e in events {
            if let k = e.push {
                b.push(seq: UInt32(k + 1), pcm: block())
                pushed += 240
            } else {
                let playing = pushed >= target
                out += pull(&b, 256)
                if playing { pulled += 256 }
            }
            XCTAssertEqual(b.bufferedFrames, pushed - pulled, "frames dropped at \(e.t)")
            if b.bufferedFrames != pushed - pulled { return }
        }
        XCTAssertEqual(b.underruns, 0)
        let start = try! XCTUnwrap(out.firstIndex { $0 != 0 })
        XCTAssertTrue(out[(start + JitterBuffer.fadeFrames)...].allSatisfy { $0 == 1000 }, "a fade was applied after the ramp-in")
    }

    func testWrongSizeDropped() {
        var b = JitterBuffer()
        b.push(seq: 1, pcm: Data(count: 100))
        XCTAssertEqual(b.bufferedFrames, 0)
        b.push(seq: 1, pcm: block())
        XCTAssertEqual(b.bufferedFrames, 240)
    }

    func testResetAcceptsLowerSeq() {
        var b = JitterBuffer()
        for seq in 100...104 { b.push(seq: UInt32(seq), pcm: block()) }
        b.reset()
        XCTAssertEqual(b.bufferedFrames, 0)
        for seq in 1...5 { b.push(seq: UInt32(seq), pcm: block()) }
        XCTAssertEqual(b.bufferedFrames, 1200)
        XCTAssertEqual(b.lostBlocks, 0)
        let s = pull(&b, 240)
        XCTAssertEqual(s[0], 0)
        assertRising(s[0..<48])
        XCTAssertTrue(s[48...].allSatisfy { $0 == 1000 })
    }

    /// The ring is walked round more than twice with content in it: every pull is one block's value, in order.
    func testRingWrapKeepsContentInOrder() {
        var b = JitterBuffer()
        var seen: [Int16] = []
        for n in 1...60 {
            b.push(seq: UInt32(n), pcm: block(Int16(n * 10)))
            let s = pull(&b, Self.blockFrames)
            if n >= 8 {
                XCTAssertEqual(Set(s).count, 1, "pull \(n) mixes blocks")
                seen.append(s[0])
            }
        }
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(Set(seen).count, seen.count, "a block played twice or skipped")
        XCTAssertEqual(b.underruns, 0)
        XCTAssertEqual(b.lostBlocks, 0)
    }

    /// While filling, a pull is silence and takes nothing out.
    func testFillingPullTakesNothing() {
        var b = JitterBuffer()
        b.push(seq: 1, pcm: block())
        b.push(seq: 2, pcm: block())
        let before = b.bufferedFrames
        XCTAssertEqual(pull(&b, 100), [Int16](repeating: 0, count: 100))
        XCTAssertEqual(b.bufferedFrames, before)
        XCTAssertEqual(b.underruns, 0)
    }

    /// Running dry by a few frames: the tail fades to silence, one underrun, nothing is left.
    func testShortUnderrunFadesTheTail() {
        var b = JitterBuffer()
        for seq in 1...5 { b.push(seq: UInt32(seq), pcm: block()) }
        let s = pull(&b, 1250)
        XCTAssertEqual(b.underruns, 1)
        XCTAssertEqual(b.bufferedFrames, 0)
        XCTAssertEqual(s[1249], 0)
        XCTAssertTrue(s[1200...].allSatisfy { $0 <= 1000 })
    }

    func testPullZeroChangesNothing() {
        var b = JitterBuffer()
        for seq in 1...5 { b.push(seq: UInt32(seq), pcm: block()) }
        let before = b.bufferedFrames
        XCTAssertEqual(pull(&b, 0), [])
        XCTAssertEqual(b.bufferedFrames, before)
        XCTAssertEqual(b.underruns, 0)
    }
}
