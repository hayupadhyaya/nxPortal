import XCTest
@testable import PortalPlayer

final class TroubleStageTests: XCTestCase {
    func testNoSilenceOrUnderASecondIsNone() {
        XCTAssertEqual(TroubleStage.at(silence: nil, ended: nil), .none)
        XCTAssertEqual(TroubleStage.at(silence: 0.5, ended: nil), .none)
        XCTAssertEqual(TroubleStage.at(silence: 0.999, ended: nil), .none)
    }

    func testOneToThreeSecondsIsThePill() {
        XCTAssertEqual(TroubleStage.at(silence: 1.0, ended: nil), .pill)
        XCTAssertEqual(TroubleStage.at(silence: 2.9, ended: nil), .pill)
    }

    func testThreeSecondsAndMoreIsReconnecting() {
        XCTAssertEqual(TroubleStage.at(silence: 3.0, ended: nil), .reconnecting)
        XCTAssertEqual(TroubleStage.at(silence: 9.9, ended: nil), .reconnecting)
    }

    func testEndedWinsAtAnySilence() {
        XCTAssertEqual(TroubleStage.at(silence: 0.2, ended: "x"), .ended(reason: "x"))
        XCTAssertEqual(TroubleStage.at(silence: nil, ended: "x"), .ended(reason: "x"))
        XCTAssertEqual(TroubleStage.at(silence: 5, ended: "x"), .ended(reason: "x"))
    }

    func testTheSentences() {
        XCTAssertEqual(Messages.sessionEnded(mac: "Den Mac", game: "Lantern"), "Den Mac stopped answering. Lantern is paused there and waits.")
        XCTAssertEqual(Messages.reconnectingTitle(mac: "Den Mac"), "Reconnecting to Den Mac")
        XCTAssertEqual(Messages.reconnectingBody(game: "Lantern"), "Lantern is paused until you're back. Try moving closer to the Wi-Fi router.")
        XCTAssertEqual(Messages.theGame, "The game")
    }

    func testThePictureTreatmentIsTheSpecs() {
        XCTAssertEqual(TroubleStage.none.pictureBlur, 0)
        XCTAssertEqual(TroubleStage.pill.pictureBlur, 0)
        XCTAssertEqual(TroubleStage.pill.pictureBrightness, 1)
        XCTAssertEqual(TroubleStage.reconnecting.pictureBlur, 14)
        XCTAssertEqual(TroubleStage.reconnecting.pictureBrightness, 0.55)
        XCTAssertEqual(TroubleStage.ended(reason: "x").pictureBlur, 18)
        XCTAssertEqual(TroubleStage.ended(reason: "x").pictureBrightness, 0.40)
    }

    func testOnlyTheCoveringStagesTakeTheScreen() {
        XCTAssertFalse(TroubleStage.none.covers)
        XCTAssertFalse(TroubleStage.pill.covers)
        XCTAssertTrue(TroubleStage.reconnecting.covers)
        XCTAssertTrue(TroubleStage.ended(reason: "x").covers)
    }

    func testTheEndedSentenceIsBuiltFromTheStoppedAnsweringCase() {
        XCTAssertEqual(Messages.sessionEnded(mac: "Den Mac", game: "Lantern"),
                       Messages.sentence(.stoppedAnswering, mac: "Den Mac") + " Lantern is paused there and waits.")
    }
}

/// The words over the dimmed picture: the picture is multiplied by the stage's brightness, the palette's scrim goes over it,
/// the text over that (the ended card: thick glass over the same, its buttons on it). A black, a mid-grey and a WHITE picture.
final class TroubleContrastTests: XCTestCase {
    private let pictures: [(String, RGBA)] = [("black", RGBA(0x000000)), ("grey", RGBA(0x808080)), ("white", RGBA(0xFFFFFF))]
    private let palettes: [(String, LookPalette)] = [("dark", LookTokens.dark), ("light", LookTokens.light)]

    private func dimmed(_ pic: RGBA, _ stage: TroubleStage) -> RGBA {
        let k = stage.pictureBrightness
        return RGBA(r: pic.r * k, g: pic.g * k, b: pic.b * k)
    }

    func testTheReconnectingTextAndSpinnerOverAnyPicture() {
        for (pn, p) in palettes {
            for (name, pic) in pictures {
                let ground = p.scrim.over(dimmed(pic, .reconnecting))
                XCTAssertGreaterThanOrEqual(Contrast.ratio(LookTokens.troubleText, ground), 4.5, "text, \(pn), \(name) picture")
                let button = p.fill2.over(ground)
                XCTAssertGreaterThanOrEqual(Contrast.ratio(LookTokens.troubleText, button), 4.5, "button text, \(pn), \(name) picture")
            }
        }
    }

    func testTheEndedCardOverAnyPicture() {
        for (pn, p) in palettes {
            for (name, pic) in pictures {
                let card = p.thickGlass.over(p.scrim.over(dimmed(pic, .ended(reason: ""))))
                func check(_ what: String, _ c: RGBA, _ on: RGBA) {
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(c, on), 4.5, "\(what), \(pn), \(name) picture")
                }
                check("title and sentence", p.text, card)
                check("Back to games", p.text, p.fill2.over(card))
                check("Reconnect", p.onAccent, p.accentFill)
            }
        }
    }
}
