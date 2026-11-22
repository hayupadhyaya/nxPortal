#if os(macOS)
import XCTest
import Foundation
import PortalKit
@testable import PortalHostCore

final class GameOptionsStoreTests: XCTestCase {
    private var dir: URL!
    private let a = "FAKE000000000000", b = "FAKE000000000001"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxportal-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var file: URL { dir.appendingPathComponent("nested/options.json") }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testSetReadAndReset() {
        let store = GameOptionsStore(fileURL: file)
        XCTAssertEqual(store.choices(titleID: a), [:])
        XCTAssertTrue(store.set("0.75", env: "DM_RENDER_SCALE", titleID: a))
        XCTAssertTrue(store.set("30", env: "DM_FPS_TARGET", titleID: a))
        XCTAssertEqual(store.choices(titleID: a), ["DM_RENDER_SCALE": "0.75", "DM_FPS_TARGET": "30"])
        XCTAssertTrue(store.set(nil, env: "DM_FPS_TARGET", titleID: a))
        XCTAssertEqual(store.choices(titleID: a), ["DM_RENDER_SCALE": "0.75"])
        store.reset(titleID: a)
        XCTAssertEqual(store.choices(titleID: a), [:])
    }

    func testAValueEqualToTheDefaultRemovesTheKey() {
        let store = GameOptionsStore(fileURL: file)
        store.set("0.75", env: "DM_RENDER_SCALE", titleID: a)
        store.set("1", env: "DM_RENDER_SCALE", titleID: a, default: "1")
        XCTAssertEqual(store.choices(titleID: a), [:], "the tested default is the absence of a choice")
    }

    func testTitlesDoNotMix() {
        let store = GameOptionsStore(fileURL: file)
        store.set("1", env: "DM_X", titleID: a)
        store.set("2", env: "DM_X", titleID: b)
        store.reset(titleID: a)
        XCTAssertEqual(store.choices(titleID: a), [:])
        XCTAssertEqual(store.choices(titleID: b), ["DM_X": "2"])
    }

    func testItSurvivesARestartAndTheFileIsPrivate() throws {
        let first = GameOptionsStore(fileURL: file)
        first.set("0.75", env: "DM_RENDER_SCALE", titleID: a)
        XCTAssertEqual(GameOptionsStore(fileURL: file).choices(titleID: a), ["DM_RENDER_SCALE": "0.75"])
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        first.set("0.5", env: "DM_RENDER_SCALE", titleID: a)
        XCTAssertEqual(try mode(file), 0o600, "a rewrite keeps it")
    }

    func testNothingIsWrittenUntilSomethingIsSet() {
        let store = GameOptionsStore(fileURL: file)
        _ = store.choices(titleID: a)
        store.reset(titleID: a)
        store.set(nil, env: "DM_X", titleID: a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "a read or an empty removal creates nothing")
    }

    func testACorruptFileReadsEmptyAndIsNotOverwrittenUntilTheNextSet() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data("{not json".utf8)
        try junk.write(to: file)
        let store = GameOptionsStore(fileURL: file)
        XCTAssertEqual(store.choices(titleID: a), [:])
        store.reset(titleID: a)
        store.set(nil, env: "DM_X", titleID: a)
        XCTAssertEqual(try Data(contentsOf: file), junk, "reads and removals leave the file alone")
        XCTAssertTrue(store.set("1", env: "DM_X", titleID: a))
        XCTAssertEqual(GameOptionsStore(fileURL: file).choices(titleID: a), ["DM_X": "1"])
        let kept = try Data(contentsOf: file.appendingPathExtension("corrupt"))
        XCTAssertEqual(kept, junk, "what was there is kept beside it, not lost")
    }

    /// A set whose write fails leaves the corrupt file where it was: it is moved aside only for a replacement that was written.
    func testAFailedWriteLeavesTheCorruptFileInPlace() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data("{not json".utf8)
        try junk.write(to: file)
        let store = GameOptionsStore(fileURL: file)
        // Writes over 1 byte fail (EFBIG) for this one call; the signal that would end the process is ignored meanwhile.
        var old = rlimit()
        getrlimit(RLIMIT_FSIZE, &old)
        var tiny = old
        tiny.rlim_cur = 1
        let oldSignal = signal(SIGXFSZ, SIG_IGN)
        setrlimit(RLIMIT_FSIZE, &tiny)
        let saved = store.set("1", env: "DM_X", titleID: a)
        setrlimit(RLIMIT_FSIZE, &old)
        signal(SIGXFSZ, oldSignal)
        XCTAssertFalse(saved)
        XCTAssertEqual(try? Data(contentsOf: file), junk, "the corrupt file was moved aside for a write that failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
        XCTAssertTrue(store.set("1", env: "DM_X", titleID: a))
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("corrupt")), junk)
    }

    func testAFileOfTheWrongShapeIsCorruptToo() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["[1]", #"{"titles":{"T":{"DM_X":5}}}"#, #"{"titles":[]}"#, ""] {
            try Data(text.utf8).write(to: file)
            XCTAssertEqual(GameOptionsStore(fileURL: file).choices(titleID: "T"), [:], text)
        }
    }

    func testNoFileMeansInMemory() {
        let store = GameOptionsStore(fileURL: nil)
        store.set("1", env: "DM_X", titleID: a)
        XCTAssertEqual(store.choices(titleID: a), ["DM_X": "1"])
        XCTAssertEqual(GameOptionsStore(fileURL: nil).choices(titleID: a), [:], "nothing is shared between stores")
    }

    func testAnUnwritableFolderRefusesTheChangeAndKeepsTheOldChoices() throws {
        let store = GameOptionsStore(fileURL: file)
        store.set("1", env: "DM_X", titleID: a)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: file.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path) }
        guard getuid() != 0 else { return }
        XCTAssertFalse(store.set("2", env: "DM_X", titleID: a))
        XCTAssertEqual(store.choices(titleID: a), ["DM_X": "1"], "what is not saved is not kept")
    }

    func testTheStoreIsBounded() {
        let store = GameOptionsStore(fileURL: nil)
        for i in 0..<(GameOptionsStore.maxChoicesPerTitle + 5) { store.set("1", env: "DM_V\(i)", titleID: a) }
        XCTAssertEqual(store.choices(titleID: a).count, GameOptionsStore.maxChoicesPerTitle)
        XCTAssertFalse(store.set("1", env: "DM_ONE_MORE", titleID: a))
        XCTAssertTrue(store.set("2", env: "DM_V0", titleID: a), "a change of one that is kept is not a new one")
        for i in 0..<(GameOptionsStore.maxTitles + 5) { store.set("1", env: "DM_X", titleID: String(format: "%016d", i)) }
        XCTAssertLessThanOrEqual(store.titleCount, GameOptionsStore.maxTitles)
        XCTAssertFalse(store.set("1", env: "DM_X", titleID: String(repeating: "T", count: 33)), "no title that is not a title ID")
        XCTAssertFalse(store.set(String(repeating: "x", count: 129), env: "DM_X", titleID: b), "no value over 128 bytes")
        XCTAssertFalse(store.set("a\nb", env: "DM_X", titleID: b), "no line break")
    }

    /// The most the store accepts is the most it reads back: the caps agree, so a file it wrote is never "corrupt" to it.
    func testTheWriteCapAndTheReadCapAreOneAndTheStoresLimitsFitUnderIt() {
        let perChoice = OptionLimits.maxEnvBytes + OptionLimits.maxValueBytes + 8  // quotes, colon, comma
        let perTitle = GameOptionsStore.maxTitleBytes + 8 + GameOptionsStore.maxChoicesPerTitle * perChoice
        XCTAssertLessThanOrEqual(GameOptionsStore.maxTitles * perTitle + 64, GameOptionsStore.maxFileBytes)
        XCTAssertEqual(GameOptionsStore.maxChoicesPerTitle, OptionLimits.maxSettings)
    }

    func testAChoiceOfAnUntrustedNameIsKeptAsTextOnly() throws {
        let store = GameOptionsStore(fileURL: file)
        store.set("a\"b\\c", env: "DM_X", titleID: a)
        XCTAssertEqual(GameOptionsStore(fileURL: file).choices(titleID: a), ["DM_X": "a\"b\\c"])
    }
}
#endif
