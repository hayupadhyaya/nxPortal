import CoreGraphics
import XCTest
@testable import PortalPlayer

final class IconDecoderTests: XCTestCase {
    /// Counts what the decode closure does: calls, and the most that ran at once.
    private final class Gauge: @unchecked Sendable {  // guarded by the lock
        private let lock = NSLock()
        private var running = 0, peakRunning = 0, calls = 0
        func enter() { lock.withLock { running += 1; peakRunning = max(peakRunning, running); calls += 1 } }
        func leave() { lock.withLock { running -= 1 } }
        var peak: Int { lock.withLock { peakRunning } }
        var count: Int { lock.withLock { calls } }
    }

    private static func pixel() -> CGImage? {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    private func decoder(limit: Int = 4, hold: TimeInterval = 0.05, _ gauge: Gauge) -> IconDecoder {
        IconDecoder(limit: limit) { _, _ in
            gauge.enter()
            Thread.sleep(forTimeInterval: hold)
            gauge.leave()
            return Self.pixel()
        }
    }

    func testManyAsksForOneIconDecodeItOnce() async {
        let gauge = Gauge()
        let d = decoder(gauge)
        let png = Data([1, 2, 3])
        let images = await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<8 { group.addTask { await d.image(key: "TITLE-hash1-64", png: png, pixels: 64) } }
            var out: [CGImage?] = []
            for await i in group { out.append(i) }
            return out
        }
        XCTAssertEqual(images.compactMap { $0 }.count, 8)
        XCTAssertEqual(gauge.count, 1, "one decode for eight asks")
        XCTAssertNotNil(d.cached("TITLE-hash1-64"))
        _ = await d.image(key: "TITLE-hash1-64", png: png, pixels: 64)
        XCTAssertEqual(gauge.count, 1, "a cached icon is not decoded again")
    }

    /// A new hash is a new key: the new icon is decoded and the old one is not what is asked for.
    func testANewHashIsDecodedUnderItsOwnKey() async {
        let gauge = Gauge()
        let d = decoder(gauge)
        _ = await d.image(key: "TITLE-hash1-64", png: Data([1]), pixels: 64)
        XCTAssertNil(d.cached("TITLE-hash2-64"))
        let second = await d.image(key: "TITLE-hash2-64", png: Data([2]), pixels: 64)
        XCTAssertNotNil(second)
        XCTAssertEqual(gauge.count, 2)
    }

    func testAtMostTheLimitDecodeAtOnce() async {
        let gauge = Gauge()
        let d = decoder(limit: 2, hold: 0.05, gauge)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 { group.addTask { _ = await d.image(key: "T\(i)-h-64", png: Data([UInt8(i)]), pixels: 64) } }
        }
        XCTAssertEqual(gauge.count, 10)
        XCTAssertLessThanOrEqual(gauge.peak, 2)
        XCTAssertEqual(IconDecoder.defaultLimit, 4)
    }

    /// A tile that goes away (its task cancelled) before its decode began costs no decode.
    func testACancelledAskThatHasNotStartedIsNotDecoded() async {
        let gauge = Gauge()
        let d = decoder(limit: 1, hold: 0.3, gauge)
        let first = Task { await d.image(key: "A-h-64", png: Data([1]), pixels: 64) }
        try? await Task.sleep(nanoseconds: 50_000_000)  // A is decoding and holds the only slot
        let second = Task { await d.image(key: "B-h-64", png: Data([2]), pixels: 64) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        second.cancel()
        let cancelledResult = await second.value
        _ = await first.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(gauge.count, 1, "the cancelled ask was decoded")
        XCTAssertNil(d.cached("B-h-64"))
    }

    private static func image(_ w: Int, _ h: Int) -> CGImage? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    /// An ask that comes right after the only asker of a waiting decode was cancelled still gets its image.
    func testAnAskJoiningACancelledWaitingDecodeStillGetsItsImage() async {
        for round in 0..<20 {
            let gauge = Gauge()
            let d = decoder(limit: 1, hold: 0.15, gauge)
            let busy = Task { await d.image(key: "BUSY\(round)-h-64", png: Data([1]), pixels: 64) }
            try? await Task.sleep(nanoseconds: 30_000_000)  // the only slot is taken
            let key = "A\(round)-h-64"
            let first = Task { await d.image(key: key, png: Data([2]), pixels: 64) }
            try? await Task.sleep(nanoseconds: 20_000_000)  // `first` waits for the slot
            first.cancel()
            let second = await d.image(key: key, png: Data([2]), pixels: 64)
            XCTAssertNotNil(second, "round \(round): the second ask got no image")
            _ = await busy.value
            if second == nil { return }
        }
    }

    /// Cancelled asks leave nothing behind: no in-flight entries, and the decoder still serves the next ask.
    func testCancelledAsksLeaveNothingBehind() async {
        let gauge = Gauge()
        let d = decoder(limit: 2, hold: 0.02, gauge)
        for i in 0..<60 {
            let t = Task { await d.image(key: "C\(i)-h-64", png: Data([1]), pixels: 64) }
            try? await Task.sleep(nanoseconds: UInt64(i % 7) * 1_500_000)
            t.cancel()
            _ = await t.value
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(d.pendingCount, 0, "entries or cancel marks kept after the asks were cancelled")
        let last = await d.image(key: "LAST-h-64", png: Data([1]), pixels: 64)
        XCTAssertNotNil(last)
    }

    /// What is kept is bounded in bytes (width x height x 4), the newest first; a memory warning drops all of it.
    func testTheCacheIsBoundedInBytesAndDroppedOnTrim() async {
        let d = IconDecoder(limit: 2, cacheLimit: 100, byteLimit: 3 * 100 * 100 * 4) { _, _ in Self.image(100, 100) }
        for i in 0..<6 { _ = await d.image(key: "K\(i)-h-100", png: Data([UInt8(i)]), pixels: 100) }
        let kept = (0..<6).filter { d.cached("K\($0)-h-100") != nil }
        XCTAssertEqual(kept, [3, 4, 5], "three 100 x 100 icons fit the budget")
        XCTAssertLessThanOrEqual(d.cachedBytes, 3 * 100 * 100 * 4)
        d.trim()
        XCTAssertEqual((0..<6).filter { d.cached("K\($0)-h-100") != nil }, [])
        XCTAssertEqual(d.cachedBytes, 0)
        let again = await d.image(key: "K5-h-100", png: Data([5]), pixels: 100)
        XCTAssertNotNil(again, "a trimmed icon is decoded again")
    }

    /// One icon larger than the whole budget is still shown (and kept alone).
    func testAnIconLargerThanTheBudgetIsKeptAlone() async {
        let d = IconDecoder(limit: 1, cacheLimit: 100, byteLimit: 1000) { _, _ in Self.image(100, 100) }
        _ = await d.image(key: "BIG-h-100", png: Data([1]), pixels: 100)
        XCTAssertNotNil(d.cached("BIG-h-100"))
    }
}
