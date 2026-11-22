import XCTest
@testable import PortalKit
@testable import PortalPlayer

final class RenderSizesTests: XCTestCase {
    private let all: [(UInt16, UInt16)] = [(1280, 720), (1920, 1080), (2560, 1440)]

    private func enabled(_ known: RenderSize?) -> [Bool] {
        RenderSizes.offered(all: all, known: known).map(\.enabled)
    }

    func testNothingKnownOffersEverything() {
        XCTAssertEqual(enabled(nil), [true, true, true])
        XCTAssertEqual(RenderSizes.offered(all: all, known: nil).map { "\($0.size.0)x\($0.size.1)" }, ["1280x720", "1920x1080", "2560x1440"])
    }

    func testAnExactSizeDisablesWhatIsAboveIt() {
        XCTAssertEqual(enabled(RenderSize(width: 1920, height: 1080, exact: true)), [true, true, false])
        XCTAssertEqual(enabled(RenderSize(width: 1600, height: 900, exact: true)), [true, false, false])
    }

    /// A lower bound (the cap held the game) allows the next size up, to find out, and nothing beyond it.
    func testALowerBoundOffersOneStepAbove() {
        XCTAssertEqual(enabled(RenderSize(width: 1280, height: 720, exact: false)), [true, true, false])
        XCTAssertEqual(enabled(RenderSize(width: 2560, height: 1440, exact: false)), [true, true, true])
    }

    func testTheEffectiveSizeIsTheSmallerOfTheCapAndTheGamesOwn() {
        let own = RenderSize(width: 1920, height: 1080, exact: true)
        let e = RenderSizes.effective(cap: (2560, 1440), known: own)
        XCTAssertEqual(e.width, 1920); XCTAssertEqual(e.height, 1080); XCTAssertEqual(e.reason, "this game's own size")
        let held = RenderSizes.effective(cap: (1280, 720), known: own)
        XCTAssertEqual(held.width, 1280); XCTAssertEqual(held.reason, "your size setting")
        let none = RenderSizes.effective(cap: (1920, 1080), known: nil)
        XCTAssertEqual(none.width, 1920); XCTAssertEqual(none.reason, "your size setting")
        let bound = RenderSizes.effective(cap: (1280, 720), known: RenderSize(width: 1280, height: 720, exact: false))
        XCTAssertEqual(bound.reason, "your size setting")
    }

    func testTheOneLineAndTheNote() {
        XCTAssertEqual(RenderSizes.line(width: 1920, height: 1080, reason: "this game's own size"), "1920 × 1080 · this game's own size")
        XCTAssertEqual(RenderSizes.aboveNote, "Above what this game renders")
    }

    /// A lower bound keeps offered every size up to the first one strictly larger than it on BOTH sides, so a person can raise
    /// the cap and learn the game's real size.
    func testALowerBoundLeavesTheNextLargerSizeOpen() {
        XCTAssertEqual(enabled(RenderSize(width: 1728, height: 1080, exact: false)), [true, true, true], "a 16:10 game under 1920 x 1080")
        XCTAssertEqual(enabled(RenderSize(width: 1440, height: 1080, exact: false)), [true, true, true], "a 4:3 game")
        XCTAssertEqual(enabled(RenderSize(width: 606, height: 1080, exact: false)), [true, true, true], "a portrait game")
        XCTAssertEqual(enabled(RenderSize(width: 1920, height: 1080, exact: false)), [true, true, true])
        XCTAssertEqual(enabled(RenderSize(width: 1280, height: 720, exact: false)), [true, true, false])
        XCTAssertEqual(enabled(RenderSize(width: 1000, height: 600, exact: false)), [true, false, false])
    }

    func testBadReportsAreNotPlausible() {
        XCTAssertFalse(RenderSizes.plausible(RenderSize(width: 0, height: 0, exact: true)))
        XCTAssertFalse(RenderSizes.plausible(RenderSize(width: 1920, height: 0, exact: true)))
        XCTAssertFalse(RenderSizes.plausible(RenderSize(width: 100, height: 50, exact: true)))
        XCTAssertFalse(RenderSizes.plausible(RenderSize(width: 65535, height: 65535, exact: false)))
        XCTAssertTrue(RenderSizes.plausible(RenderSize(width: 320, height: 180, exact: true)))
        XCTAssertTrue(RenderSizes.plausible(RenderSize(width: 7680, height: 4320, exact: false)))
    }

    func testMergeRules() {
        let exact1080 = RenderSize(width: 1920, height: 1080, exact: true)
        let bound720 = RenderSize(width: 1280, height: 720, exact: false)
        XCTAssertEqual(RenderSizes.merged(old: nil, new: bound720), bound720)
        XCTAssertNil(RenderSizes.merged(old: exact1080, new: bound720), "an exact size is not replaced by a lower bound under it")
        XCTAssertNil(RenderSizes.merged(old: exact1080, new: exact1080))
        let exact720 = RenderSize(width: 1280, height: 720, exact: true)
        XCTAssertEqual(RenderSizes.merged(old: exact1080, new: exact720), exact720, "a new exact size replaces the old")
        let bound1440 = RenderSize(width: 2560, height: 1440, exact: false)
        XCTAssertEqual(RenderSizes.merged(old: exact1080, new: bound1440), bound1440, "a larger lower bound replaces a smaller exact one")
        XCTAssertEqual(RenderSizes.merged(old: bound720, new: exact720), exact720)
        // A bound only grows; an exact size replaces any bound it is not below.
        let bound1080 = RenderSize(width: 1920, height: 1080, exact: false)
        XCTAssertNil(RenderSizes.merged(old: bound1080, new: bound720), "a smaller lower bound does not replace a larger one")
        XCTAssertEqual(RenderSizes.merged(old: bound720, new: bound1080), bound1080)
        XCTAssertNil(RenderSizes.merged(old: bound1080, new: exact720), "an exact size below the bound is not believed over it")
        XCTAssertEqual(RenderSizes.merged(old: bound720, new: RenderSize(width: 1920, height: 1080, exact: true)), RenderSize(width: 1920, height: 1080, exact: true))
        XCTAssertEqual(RenderSizes.merged(old: bound1080, new: RenderSize(width: 1920, height: 1080, exact: true)), RenderSize(width: 1920, height: 1080, exact: true))
    }

    /// One definition: the stored-size check and the artwork cache's agree on every ID.
    func testOneTitleCheckForSizesAndArtwork() {
        let hash = String(repeating: "a", count: 64)
        for id in ["0400486024DEC000", "FAKE000000000000", "", "a b", String(repeating: "A", count: 40), "ä123", "abc-def", "x"] {
            XCTAssertEqual(TitleID.isWellFormed(id), ArtCache.safe(titleID: id, hash: hash), id)
        }
    }

    func testTitleIDsMustBeWellFormed() {
        XCTAssertTrue(TitleID.isWellFormed( "0400486024DEC000"))
        XCTAssertTrue(TitleID.isWellFormed( "FAKE000000000000"))
        XCTAssertFalse(TitleID.isWellFormed( ""))
        XCTAssertFalse(TitleID.isWellFormed( "a b"))
        XCTAssertFalse(TitleID.isWellFormed( String(repeating: "A", count: 40)))
    }

    func testTheNoteJoinsTheLineAndTheReasonForDisabledSizes() {
        XCTAssertEqual(RenderSizes.note(line: "1920 × 1080 · this game's own size", someAbove: true),
                       "1920 × 1080 · this game's own size\nAbove what this game renders")
        XCTAssertEqual(RenderSizes.note(line: "1920 × 1080 · this game's own size", someAbove: false), "1920 × 1080 · this game's own size")
        XCTAssertNil(RenderSizes.note(line: nil, someAbove: false))
    }
}
