import XCTest
import PortalKit
@testable import PortalPlayer

final class LibraryCacheTests: XCTestCase {
    private var dir: URL!
    private let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
    private let one = GameEntry(titleID: "FAKE000000000000", name: "One", streamable: true, state: .idle)
    private let two = GameEntry(titleID: "FAKE000000000001", name: "Two", streamable: false, state: .paused)

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxp-c-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSavedGamesReadBackInOrderPerMac() {
        let cache = LibraryCache(directory: dir)
        cache.save([two, one], for: a)
        XCTAssertEqual(cache.games(for: a), [two, one])
        XCTAssertEqual(cache.games(for: b), [])
    }

    func testSavingTwiceReplaces() {
        let cache = LibraryCache(directory: dir)
        cache.save([one, two], for: a)
        cache.save([two], for: a)
        XCTAssertEqual(cache.games(for: a), [two])
    }

    func testADamagedFileReadsEmptyAndIsReplaced() throws {
        let cache = LibraryCache(directory: dir)
        cache.save([one], for: a)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(file.lastPathComponent.count, 16 + 5, "16 hex characters and .json")
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(cache.games(for: a), [])
        XCTAssertNil(cache.lastPlayed(for: a))
        cache.save([two], for: a)
        XCTAssertEqual(cache.games(for: a), [two])
    }

    func testAFileAboveTheSizeLimitReadsEmpty() throws {
        let cache = LibraryCache(directory: dir)
        cache.save([one], for: a)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        var data = try Data(contentsOf: file)
        XCTAssertEqual(cache.games(for: a), [one])
        data.append(Data(repeating: 0x20, count: LibraryCache.maxFileBytes))  // still valid JSON, now too big
        try data.write(to: file)
        XCTAssertEqual(cache.games(for: a), [], "an oversized file was read")
        XCTAssertNil(cache.lastPlayed(for: a))
    }

    func testLastPlayedSurvivesANewCacheAndASave() {
        LibraryCache(directory: dir).setLastPlayed("FAKE000000000000", for: a)
        let again = LibraryCache(directory: dir)
        XCTAssertEqual(again.lastPlayed(for: a), "FAKE000000000000")
        again.save([one], for: a)
        XCTAssertEqual(again.lastPlayed(for: a), "FAKE000000000000")
        XCTAssertNil(again.lastPlayed(for: b))
    }
}
