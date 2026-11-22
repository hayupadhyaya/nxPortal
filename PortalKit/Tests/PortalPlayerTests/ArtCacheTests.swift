import XCTest
import CryptoKit
import PortalKit
import PortalClientCore
@testable import PortalPlayer

/// PNGs generated here (`ImageFixtures`); no artwork from anywhere else.
final class ArtCacheTests: XCTestCase {
    private var dir: URL!
    private let title = "FAKE000000000000"

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-art-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private var files: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    func testStoreThenRead() {
        let cache = ArtCache(directory: dir)
        let png = ImageFixtures.gradient(side: 64)
        cache.store(png, titleID: title, hash: hash(png))
        XCTAssertEqual(cache.data(titleID: title, hash: hash(png)), png)
        XCTAssertEqual(files, ["\(title)-\(hash(png)).png"])
    }

    func testASecondHashForTheTitleRemovesTheFirstFiles() {
        let cache = ArtCache(directory: dir)
        let first = ImageFixtures.fill(RGBA(0x3366FF)), second = ImageFixtures.fill(RGBA(0xFF3300))
        cache.store(first, titleID: title, hash: hash(first))
        _ = cache.palette(titleID: title, hash: hash(first))
        cache.store(ImageFixtures.fill(RGBA(0x33FF66)), titleID: "FAKE000000000001", hash: hash(ImageFixtures.fill(RGBA(0x33FF66))))
        cache.store(second, titleID: title, hash: hash(second))
        XCTAssertNil(cache.data(titleID: title, hash: hash(first)))
        XCTAssertFalse(files.contains { $0.hasPrefix("\(title)-\(hash(first))") }, "\(files)")
        XCTAssertEqual(cache.data(titleID: title, hash: hash(second)), second)
        XCTAssertTrue(files.contains { $0.hasPrefix("FAKE000000000001-") }, "another title's file stays")
    }

    func testOneChangedByteReadsAsNilAndIsDeleted() throws {
        let cache = ArtCache(directory: dir)
        let png = ImageFixtures.gradient(side: 64)
        cache.store(png, titleID: title, hash: hash(png))
        let url = dir.appendingPathComponent("\(title)-\(hash(png)).png")
        var bad = try Data(contentsOf: url)
        bad[bad.count / 2] ^= 0xFF
        try bad.write(to: url)
        XCTAssertNil(cache.data(titleID: title, hash: hash(png)))
        XCTAssertEqual(files, [])
    }

    func testPaletteIsThatOfTheStoredFileAndIsKept() {
        let cache = ArtCache(directory: dir)
        let png = ImageFixtures.gradient(side: 64)
        cache.store(png, titleID: title, hash: hash(png))
        XCTAssertEqual(cache.palette(titleID: title, hash: hash(png)), ArtPalette.from(png: png))
        XCTAssertTrue(files.contains("\(title)-\(hash(png)).palette.json"), "\(files)")
        XCTAssertNil(cache.palette(titleID: title, hash: String(repeating: "0", count: 64)), "no file: no palette")
    }

    func testAStoreWhoseHashDoesNotMatchOrAnUnsafeNameWritesNothing() {
        let cache = ArtCache(directory: dir)
        let png = ImageFixtures.gradient(side: 64)
        cache.store(png, titleID: title, hash: String(repeating: "0", count: 64))
        cache.store(png, titleID: "../x", hash: hash(png))
        cache.store(png, titleID: title, hash: "../" + hash(png))
        XCTAssertEqual(files, [])
    }

    // MARK: assembly -> .claude/client.md § model

    private func chunks(_ png: Data, titleID: String? = nil) -> [ArtChunk] {
        let count = ArtChunking.count(bytes: png.count)
        return (0..<count).map { i in
            let lo = i * ArtChunking.chunkBytes
            return ArtChunk(titleID: titleID ?? title, hash: hash(png), index: UInt16(i), count: UInt16(count),
                            bytes: png.subdata(in: lo..<min(lo + ArtChunking.chunkBytes, png.count)))
        }
    }

    private func big() -> Data { Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }) }

    private func run(_ cs: [ArtChunk], _ ref: ArtRef) -> ArtTransfer.Step? {
        guard var t = ArtTransfer(titleID: title, ref: ref) else { return nil }
        var last: ArtTransfer.Step = .more
        for c in cs {
            last = t.accept(c)
            if last != .more { break }
        }
        return last
    }

    func testChunksInOrderAssembleToTheIcon() {
        let png = big()
        XCTAssertEqual(run(chunks(png), ArtRef(hash: hash(png), bytes: UInt32(png.count))), .done(png))
    }

    func testOutOfOrderWrongCountWrongTotalOrHashAreDiscarded() {
        let png = big(), ref = ArtRef(hash: hash(png), bytes: UInt32(png.count))
        var swapped = chunks(png)
        swapped.swapAt(0, 1)
        XCTAssertEqual(run(swapped, ref), .discard, "out of order")
        var count = chunks(png)
        count[0].count += 1
        XCTAssertEqual(run(count, ref), .discard, "a count that does not match bytes")
        XCTAssertEqual(run(chunks(png), ArtRef(hash: ref.hash, bytes: ref.bytes - 1)), .discard, "a wrong total")
        var flipped = chunks(png)
        flipped[1].bytes[0] ^= 1
        XCTAssertEqual(run(flipped, ref), .discard, "a hash mismatch")
        XCTAssertEqual(run(chunks(png, titleID: "FAKE000000000009"), ref), .discard, "another title")
        XCTAssertEqual(run([ArtChunk(titleID: title, hash: ref.hash, index: 0, count: 0, bytes: Data())], ref), ArtTransfer.Step.none)
    }

    func testATotalAboveTheCapIsNeverAsked() {
        XCTAssertNil(ArtTransfer(titleID: title, ref: ArtRef(hash: String(repeating: "a", count: 64), bytes: 512 * 1024 + 1)))
        XCTAssertNil(ArtTransfer(titleID: title, ref: ArtRef(hash: String(repeating: "a", count: 64), bytes: 0)))
        XCTAssertNil(ArtTransfer(titleID: title, ref: ArtRef(hash: "not hex", bytes: 10)))
        XCTAssertNotNil(ArtTransfer(titleID: title, ref: ArtRef(hash: String(repeating: "a", count: 64), bytes: 512 * 1024)))
    }
}
