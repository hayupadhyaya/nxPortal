import XCTest
import PortalKit
@testable import PortalPlayer

final class MessagesTests: XCTestCase {
    private let tail = "Showing the last known games. Check that the Mac is awake and on this network."

    func testOnlyCannotReachCarriesTheLastKnownGamesTail() {
        XCTAssertEqual(Messages.banner(.cannotReach, mac: "Den Mac"), "Cannot reach Den Mac. " + tail)
        let others: [Messages.Problem] = [.refused(.busy(device: "iPad mini 2")), .refused(.version(host: 4)), .connectionLost, .stoppedAnswering,
                                          .mediaPathBlocked, .didNotAnswer, .storeFailed, .codeDidNotMatch, .other("Paired.")]
        for p in others {
            let text = Messages.banner(p, mac: "Den Mac")
            XCTAssertFalse(text.contains("last known"), "\(p): \(text)")
            XCTAssertEqual(text, Messages.sentence(p, mac: "Den Mac"))
        }
    }

    /// After the retry loop has given up the banner does not say it is trying again.
    func testTheGivenUpSentenceDoesNotSayTryingAgain() {
        XCTAssertEqual(Messages.banner(.stoppedAnswering, mac: "Den Mac"), "Den Mac stopped answering.")
        XCTAssertFalse(Messages.banner(.stoppedAnswering, mac: "Den Mac").contains("Trying again"))
        XCTAssertEqual(Messages.banner(.connectionLost, mac: "Den Mac"), "Connection to the Mac lost. Trying again…")
    }

    func testEachBannerIsItsOwnSentence() {
        XCTAssertEqual(Messages.banner(.refused(.busy(device: "iPad mini 2")), mac: "Den Mac"), "Den Mac is playing on iPad mini 2.")
        XCTAssertEqual(Messages.banner(.refused(.version(host: 4)), mac: "Den Mac"),
                       "Den Mac has a different version of nxPortal Host (protocol 4, this app \(ProtocolVersion.network)). Update the older one.")
        XCTAssertEqual(Messages.banner(.connectionLost, mac: "Den Mac"), "Connection to the Mac lost. Trying again…")
        XCTAssertEqual(Messages.banner(.storeFailed, mac: "Den Mac"), Messages.storeFailed)
        XCTAssertEqual(Messages.banner(.inUse(device: "Living Room TV"), mac: "Den Mac"), "Den Mac is now in use on Living Room TV.")
        XCTAssertEqual(Messages.banner(.inUse(device: nil), mac: "Den Mac"), "Den Mac is now in use on another device.")
    }

    /// A device name from the wire is shown clean and bounded, never as it came.
    func testADeviceNameFromTheWireIsShownClean() {
        let hostile = "\u{7}Den\u{202E}\n" + String(repeating: "x", count: 5_000)
        for text in [Messages.banner(.refused(.busy(device: hostile)), mac: "Den Mac"), Messages.banner(.inUse(device: hostile), mac: "Den Mac"),
                     Messages.refusal(.busy(device: hostile), mac: "Den Mac")] {
            XCTAssertFalse(text.contains("\u{7}") || text.contains("\u{202E}") || text.contains("\n"), text)
            XCTAssertLessThan(text.utf8.count, 220, "bounded")
            XCTAssertTrue(text.contains("Den x"), text)
        }
        XCTAssertEqual(Messages.banner(.inUse(device: " \n "), mac: "Den Mac"), "Den Mac is now in use on another device.")
        XCTAssertEqual(Messages.banner(.refused(.busy(device: "")), mac: "Den Mac"), "Den Mac is playing on another device.")
    }

    func testCannotReachWithDiscoveryRefusedSaysSo() {
        let text = Messages.banner(.cannotReach, mac: "Den Mac", discoveryBlocked: true)
        XCTAssertEqual(text, "Cannot reach Den Mac. " + Messages.discoveryBlocked)
        XCTAssertFalse(text.contains("last known"))
    }

    func testTheSentencesTheViewsShow() {
        XCTAssertEqual(Messages.playing("Lantern"), "Playing Lantern")
        XCTAssertEqual(Messages.switchTitle("Den Mac"), "Switch to Den Mac?")
        XCTAssertEqual(Messages.switchMessage(game: "Lantern", mac: "Den Mac"), "Lantern is playing on Den Mac. It pauses there and waits for you.")
        XCTAssertEqual(Messages.pairTitle(mac: "Den Mac"), "Pair with Den Mac")
        XCTAssertEqual(Messages.pairText(mac: "Den Mac"), "Type the six-digit code shown in the nxPortal menu on Den Mac.")
        XCTAssertEqual(Messages.codeLabel(3), "Code, 3 of 6 digits")
        XCTAssertEqual(Messages.onMac("Den Mac"), "On Den Mac")
        XCTAssertEqual(Messages.controller("Pad"), "Controller: Pad")
        XCTAssertEqual(Messages.macsButton(nil), "Macs")
        XCTAssertEqual(Messages.macsButton("Den Mac"), "Den Mac")
        XCTAssertEqual(Messages.mbitOption(50), "50 Mbit/s")
        XCTAssertEqual(Messages.fpsOption(60), "60 fps")
        XCTAssertEqual(Messages.msOption(40), "40 ms")
    }

    func testTypeItAgainIsForAWrongCodeOnly() {
        XCTAssertEqual(Messages.pairRetry(.wrongCode(triesLeft: 2), mac: "Den Mac"), "Check the code on Den Mac and type it again.")
        XCTAssertNil(Messages.pairRetry(.locked, mac: "Den Mac"))
        XCTAssertNil(Messages.pairRetry(.expired, mac: "Den Mac"))
        XCTAssertNil(Messages.pairRetry(nil, mac: "Den Mac"))
    }
}
