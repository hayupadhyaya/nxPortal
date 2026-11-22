import XCTest
@testable import PortalKit

/// One clean-up for a device's name, on the device and on the Host -> .claude/portalkit.md § wire-network
final class DeviceNameTests: XCTestCase {
    private func cases() -> [String] {
        ["\u{0007} iPad   mini \n", "Den\u{202E} iPad", String(repeating: "a", count: 39) + " b", " \n ", "\u{7} x",
         String(repeating: "x", count: 60), String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 40),
         "a\u{200C}b", "plain", "a\nb\tc", String(repeating: "\u{00E9}", count: 70)]
    }

    func testTheTable() {
        XCTAssertEqual(DeviceName.clean("\u{0007} iPad   mini \n"), "iPad mini")
        XCTAssertEqual(DeviceName.clean("Den\u{202E} iPad"), "Den iPad")
        XCTAssertEqual(DeviceName.clean(String(repeating: "a", count: 39) + " b"), String(repeating: "a", count: 39))
        XCTAssertNil(DeviceName.clean(" \n "))
        XCTAssertNil(DeviceName.clean(""))
        XCTAssertEqual(DeviceName.clean("\u{7} x"), "x")
    }

    func testNewlinesAndTabsAreSpacesNotNothing() {
        XCTAssertEqual(DeviceName.clean("a\nb\t c"), "a b c")
    }

    func testALongNameIsCutToFortyCharacters() {
        let cut = DeviceName.clean(String(repeating: "x", count: 60))
        XCTAssertEqual(cut?.count, 40)
    }

    func testBytesAreBoundedAndClustersStayWhole() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let cut = try XCTUnwrap(DeviceName.clean(String(repeating: family, count: 40)))
        XCTAssertLessThanOrEqual(cut.utf8.count, DeviceName.maxBytes)
        XCTAssertGreaterThan(cut.count, 0)
        XCTAssertEqual(cut, String(repeating: family, count: cut.count), "every cluster is intact, U+200D kept")
        let two = try XCTUnwrap(DeviceName.clean(String(repeating: "\u{00E9}", count: 70)))
        XCTAssertLessThanOrEqual(two.count, 40)
        XCTAssertLessThanOrEqual(two.utf8.count, 120)
    }

    func testZeroWidthJoinersAreKept() {
        XCTAssertEqual(DeviceName.clean("a\u{200C}b"), "a\u{200C}b")
        XCTAssertEqual(DeviceName.clean("a\u{200D}b"), "a\u{200D}b")
    }

    func testFormatAndBidiControlsAreRemoved() {
        XCTAssertEqual(DeviceName.clean("a\u{200E}\u{200F}\u{202A}\u{2066}\u{FEFF}\u{00AD}b"), "ab")
    }

    /// A name nobody can see is no name.
    func testANameWithNothingVisibleIsNil() {
        for raw in ["\u{200D}", "\u{200C}\u{200D}", "\u{2800}", "\u{3164}\u{115F}\u{1160}\u{FFA0}", "\u{E000}", "\u{0378}", " \u{200D} ",
                    "\u{2800} \u{3164}"] {
            XCTAssertNil(DeviceName.clean(raw), raw.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
        XCTAssertEqual(DeviceName.clean("\u{2800}a"), "\u{2800}a", "one visible character is enough")
        XCTAssertEqual(DeviceName.clean("\u{1F468}\u{200D}\u{1F469}"), "\u{1F468}\u{200D}\u{1F469}")
        XCTAssertEqual(DeviceName.clean("."), ".")
    }

    func testCleanIsIdempotent() {
        for raw in cases() {
            let once = DeviceName.clean(raw)
            XCTAssertEqual(once.flatMap(DeviceName.clean), once, raw)
        }
    }

    /// The visible check runs on the text that is kept, not on the text before the cut.
    func testABlankNameCutBeforeItsFirstVisibleCharacterIsNil() {
        let blanks = String(repeating: "\u{2800}", count: 45) + "a"
        XCTAssertNil(DeviceName.clean(blanks))
        XCTAssertNil(DeviceName.clean(String(repeating: "\u{3164}", count: 50) + "Mac"))
        XCTAssertEqual(DeviceName.clean(String(repeating: "\u{2800}", count: 30) + "a")?.count, 31)
    }

    func testCleanIsIdempotentOverHostileAndOrdinaryNames() {
        let hostile = [String(repeating: "\u{2800}", count: 45) + "a", String(repeating: "\u{3164}", count: 39) + "ab",
                       String(repeating: "\u{200D}", count: 41) + "x", String(repeating: " ", count: 39) + "a b",
                       String(repeating: "a", count: 38) + "\u{2800}\u{2800}z", "x" + String(repeating: "\u{200C}", count: 80),
                       "\u{1F600}", "\u{4E2D}\u{6587}", "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"]
        for raw in hostile + cases() {
            let once = DeviceName.clean(raw)
            XCTAssertEqual(once.flatMap(DeviceName.clean), once, "twice differs: \(raw.unicodeScalars.count) scalars")
        }
    }

    func testRealNamesSurvive() {
        let names = ["\u{1F600}\u{1F680}", "\u{4E2D}\u{6587}\u{540D}", "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}",
                     "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}",
                     "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"]
        for name in names { XCTAssertEqual(DeviceName.clean(name), name) }
    }

    func testANumberedNameStaysWithinTheLimits() {
        XCTAssertEqual(DeviceName.numbered("iPad mini", 2), "iPad mini 2")
        let long = String(repeating: "a", count: 40)
        let n = DeviceName.numbered(long, 12)
        XCTAssertLessThanOrEqual(n.count, 40)
        XCTAssertTrue(n.hasSuffix(" 12"))
        XCTAssertEqual(DeviceName.clean(n), n)
    }
}
