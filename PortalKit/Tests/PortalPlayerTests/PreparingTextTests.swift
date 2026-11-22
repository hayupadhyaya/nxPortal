import XCTest
import PortalKit
@testable import PortalPlayer

final class PreparingTextTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private func p(_ done: UInt32, _ total: UInt32) -> Preparing { Preparing(phase: 2, done: done, total: total) }
    private func q(_ phase: UInt8, _ done: UInt32, _ total: UInt32) -> Preparing { Preparing(phase: phase, done: done, total: total) }

    func testTheCountIsThePhasesOwnNumbersGroupedByTheLocale() {
        XCTAssertEqual(PreparingText.count(p(12_400, 34_649), locale: us), "12,400 of 34,649")
        XCTAssertEqual(PreparingText.count(p(12_400, 34_649), locale: Locale(identifier: "de_DE")), "12.400 of 34.649")
        XCTAssertEqual(PreparingText.count(q(7, 5, 50), locale: us), "5 of 50", "an unknown phase shows the same way")
    }

    func testPreparingWithoutProgressIsWaitingForTheGame() {
        XCTAssertEqual(PreparingText.display(.waiting), .waiting)
        XCTAssertEqual(PreparingText.display(q(2, 0, 0)), .waiting, "a 0-of-0 phase")
        XCTAssertEqual(PreparingText.display(q(0, 0, 5)), .progress(q(0, 0, 5)))
        XCTAssertEqual(PreparingText.waitingTitle, "Waiting for the game")
        XCTAssertEqual(PreparingText.preparingTitle, "Preparing graphics for this Mac")
        XCTAssertEqual(PreparingText.firstStartNote, "The first start on a Mac takes a few minutes. Later starts are quick.")
        XCTAssertEqual(PreparingText.leaveNote, "You can leave: this goes on.")
        XCTAssertEqual(PreparingText.waitingBody(game: "Lantern", mac: "Den Mac"),
                       "Lantern is starting on Den Mac. Nothing has come back from it yet; this can take a minute.")
    }

    func testElapsedAndTheWaitingClock() {
        XCTAssertEqual(PreparingText.elapsed(192), "3 min 12 s so far")
        XCTAssertEqual(PreparingText.elapsed(42), "42 s so far")
        XCTAssertEqual(PreparingText.elapsed(3_720), "1 h 2 min so far")
        XCTAssertEqual(PreparingText.elapsed(-5), "0 s so far")
        XCTAssertEqual(PreparingText.clock(42), "0:42")
        XCTAssertEqual(PreparingText.clock(192), "3:12")
        XCTAssertEqual(PreparingText.clock(3_725), "1:02:05")
    }

    func testVoiceOverAnnouncesEveryQuarter() {
        XCTAssertEqual(PreparingText.accessibilityValue(p(12_400, 34_649)), "Preparing graphics, 36 percent")
        XCTAssertEqual(PreparingText.accessibilityValue(.waiting), "Waiting for the game")
        XCTAssertNil(PreparingText.announcement(from: nil, to: 10))
        XCTAssertNil(PreparingText.announcement(from: 10, to: 24))
        XCTAssertEqual(PreparingText.announcement(from: 24, to: 26), "Preparing graphics, 25 percent")
        XCTAssertEqual(PreparingText.announcement(from: 40, to: 51), "Preparing graphics, 50 percent")
        XCTAssertEqual(PreparingText.announcement(from: 70, to: 90), "Preparing graphics, 75 percent", "the newest crossed")
        XCTAssertNil(PreparingText.announcement(from: 26, to: 49))
        XCTAssertNil(PreparingText.announcement(from: 80, to: 99), "100 is the end of it, not announced")
    }

    /// The crossing is not lost when progress resumes after a "waiting" gap (no percent in between).
    func testTheAnnouncerRemembersThePercentThroughAWaitingGap() {
        var a = PreparingText.Announcer()
        XCTAssertNil(a.next(10))
        XCTAssertNil(a.next(nil))
        XCTAssertEqual(a.next(30), "Preparing graphics, 25 percent")
        XCTAssertNil(a.next(nil))
        XCTAssertNil(a.next(31))
        XCTAssertEqual(a.next(60), "Preparing graphics, 50 percent")
        var fresh = PreparingText.Announcer()
        XCTAssertNil(fresh.next(nil))
        XCTAssertNil(fresh.next(30), "the first percent seen is never announced")
    }

    func testTheStartingCardHeaderNamesTheGameAndTheMac() {
        XCTAssertEqual(PreparingText.header(game: "Lantern", mac: "Den Mac"), "Lantern on Den Mac")
    }

    func testTheTileShowsPreparingWithItsPercent() {
        XCTAssertEqual(PreparingText.tileCaption(percent: 36), "Preparing 36 %")
        XCTAssertEqual(PreparingText.tileCaption(percent: nil), "Preparing")
        XCTAssertEqual(LibraryText.tileValue(.preparing(percent: 36)), "Preparing, 36 percent")
        XCTAssertEqual(LibraryText.tileValue(.preparing(percent: nil)), "Preparing")
    }

    /// The in-play menu's note under Disconnect: one sentence per case (a preparing game is not paused until it is ready).
    func testTheDisconnectNoteSaysWhatHappensToTheGame() {
        XCTAssertEqual(PreparingText.disconnectNote(preparing: false), "Disconnect pauses the game and shows the games. Quit ends it.")
        XCTAssertEqual(PreparingText.disconnectNote(preparing: true),
                       "Disconnect shows the games; the game goes on preparing and pauses when it is ready. Quit ends it.")
    }

    func testTileStateFollowsTheHostsPreparing() {
        let g = GameEntry(titleID: "FAKE000000000000", name: "A", streamable: true, state: .running)
        XCTAssertEqual(LibraryText.tileState(g, reachable: true, preparing: p(12_400, 34_649)), .preparing(percent: 36))
        XCTAssertEqual(LibraryText.tileState(g, reachable: true, preparing: .waiting), .preparing(percent: nil))
        XCTAssertEqual(LibraryText.tileState(g, reachable: true, preparing: nil), .normal)
        XCTAssertEqual(LibraryText.tileState(g, reachable: false, preparing: .waiting), .unreachable, "never live-preparing on a last-known list")
        XCTAssertEqual(LibraryText.tileState(g, reachable: false, preparing: p(12_400, 34_649)), .unreachable)
        XCTAssertEqual(LibraryText.tileState(g, reachable: false, preparing: nil), .unreachable)
        XCTAssertEqual(LibraryText.tileState(GameEntry(titleID: "X", name: "A", streamable: false, state: .idle), reachable: true, preparing: .waiting), .rebuild)
        let paused = GameEntry(titleID: "FAKE000000000000", name: "A", streamable: true, state: .paused)
        XCTAssertEqual(LibraryText.tileState(paused, reachable: true, preparing: p(1, 2)), .paused, "never for a paused game")
    }
}

/// The starting screen and the tile ring draw text and a ring over the game's glow and its icon: `§ look-access`.
final class PreparingContrastTests: XCTestCase {
    private let palettes: [(String, LookPalette)] = [("dark", LookTokens.dark), ("light", LookTokens.light)]

    /// The starting screen's text is Text on thick glass over the game's glow at its strongest (Vivid at the lightness
    /// clamp, 70 % over Background), for the 12 hue buckets.
    func testTheStartingScreenTextOnItsGlassOverTheGlow() {
        let d = LookTokens.dark
        for bucket in 0..<12 {
            let vivid = RGBA.fromHSL(h: Double(bucket) * 30 + 15, s: 1, l: 0.55)
            var glow = vivid
            glow.a = 0.70
            let card = d.thickGlass.over(glow.over(d.background))
            XCTAssertGreaterThanOrEqual(Contrast.ratio(d.text, card), 4.5, "text, bucket \(bucket)")
            XCTAssertGreaterThanOrEqual(Contrast.ratio(d.text, d.fill2.over(card)), 4.5, "text on the bar's track, bucket \(bucket)")
        }
    }

    /// The tile's ring is a light arc over a scrim over any icon (black, mid grey, white): a graphic, 3:1.
    func testTheTileRingOverAnyIcon() {
        for (pn, p) in palettes {
            for (name, icon) in [("black", RGBA(0x000000)), ("grey", RGBA(0x808080)), ("white", RGBA(0xFFFFFF))] {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(LookTokens.dark.text, p.scrim.over(icon)), 3, "ring over \(name) icon, \(pn)")
            }
        }
    }

    func testTheTileCaptionOverTheGlow() {
        let d = LookTokens.dark
        XCTAssertGreaterThanOrEqual(Contrast.ratio(d.tileCaption, d.background), 4.5)
    }
}
