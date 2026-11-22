import XCTest
@testable import PortalKit

final class SessionTests: XCTestCase {
  private let tv = Data([1])
  private let ipad = Data([2])

  private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

  private func liveWithGame() -> HostSessionModel {
    var m = HostSessionModel()
    _ = m.admit(device: tv, name: "Living Room", at: at(0))
    _ = m.gameStarted(at: at(0))
    m.inputReceived(at: at(0))
    return m
  }

  /// Live session whose client then went silent and was paused.
  private func pausedModel() -> HostSessionModel {
    var m = liveWithGame()
    _ = m.tick(at: at(10.1))
    return m
  }

  // MARK: library sessions (`resume: false`)

  /// A library session never resumes the game it paused; a resuming one (the default, or `resume: true`) does, as before.
  func testALibraryAdmissionLeavesTheGamePaused() {
    var m = pausedModel()
    let (admission, actions) = m.admit(device: tv, name: "Living Room", resume: false, at: at(11))
    XCTAssertEqual(admission, .accept)
    XCTAssertEqual(actions, [.holdAwake(true)])
    XCTAssertTrue(m.gamePaused)
    XCTAssertFalse(m.playing)
  }

  func testAResumingAdmissionResumesAsBefore() {
    for resume in [true, nil] as [Bool?] {
      var m = pausedModel()
      let (_, actions) = resume.map { m.admit(device: tv, name: "Living Room", resume: $0, at: at(11)) }
        ?? m.admit(device: tv, name: "Living Room", at: at(11))
      XCTAssertEqual(actions, [.holdAwake(true), .resumeGame, .requestKeyframe], "resume \(String(describing: resume))")
      XCTAssertFalse(m.gamePaused)
      XCTAssertTrue(m.playing)
    }
  }

  /// `resume` on a library session resumes and makes it the playing one; its later leave pauses as any other.
  func testResumeOnALibrarySessionPlays() {
    var m = pausedModel()
    _ = m.admit(device: tv, name: "Living Room", resume: false, at: at(11))
    XCTAssertEqual(m.resumeRequested(at: at(12)), [.resumeGame, .requestKeyframe])
    XCTAssertTrue(m.playing)
    XCTAssertFalse(m.gamePaused)
    XCTAssertEqual(m.clientLeft(at: at(13)), [.neutralPads, .pauseGame])
    XCTAssertFalse(m.playing)
  }

  /// A game that connects under a library session is paused (nobody plays it) unless that session sent `launch`.
  func testLaunchOnALibrarySessionPlaysAndTheStartingGameIsNotPaused() {
    var m = HostSessionModel()
    _ = m.admit(device: tv, name: "Living Room", resume: false, at: at(0))
    XCTAssertFalse(m.playing)
    m.launchRequested(at: at(1))
    XCTAssertTrue(m.playing)
    XCTAssertEqual(m.gameStarted(at: at(2)), [])
    XCTAssertFalse(m.gamePaused)

    var idle = HostSessionModel()
    _ = idle.admit(device: tv, name: "Living Room", resume: false, at: at(0))
    XCTAssertEqual(idle.gameStarted(at: at(2)), [.pauseGame])
    XCTAssertTrue(idle.gamePaused)
  }

  /// The paused game stays owed to the device that paused it: a library session of that device leaves and its resuming
  /// session later resumes the game.
  func testALibrarySessionThatLeavesKeepsTheGameOwedToItsPlayer() {
    var m = pausedModel()
    _ = m.admit(device: tv, name: "Living Room", resume: false, at: at(11))
    XCTAssertEqual(m.clientLeft(at: at(12)), [.neutralPads])
    let (_, actions) = m.admit(device: tv, name: "Living Room", at: at(13))
    XCTAssertEqual(actions, [.holdAwake(true), .resumeGame, .requestKeyframe])
  }

  /// A library session that replaces the same device's playing session pauses the game (it stops playing).
  func testALibrarySessionReplacingThePlayingOnePausesTheGame() {
    var m = liveWithGame()
    XCTAssertTrue(m.playing)
    let (admission, actions) = m.admit(device: tv, name: "Living Room", resume: false, at: at(1))
    XCTAssertEqual(admission, .accept)
    XCTAssertEqual(actions, [.pauseGame])
    XCTAssertTrue(m.gamePaused)
    XCTAssertFalse(m.playing)
    XCTAssertEqual(m.admit(device: tv, name: "Living Room", at: at(2)).1, [], "a resuming replacement does not resume either")
  }

  /// Another device's admission while the live session is a library one (not playing): accepted, the newcomer is live
  /// and the game stays owed to the device that paused it.
  func testALibrarySessionGivesWayToAnotherDevice() {
    var m = pausedModel()
    _ = m.admit(device: tv, name: "Living Room", resume: false, at: at(11))
    let (admission, actions) = m.admit(device: ipad, name: "iPad", at: at(12))
    XCTAssertEqual(admission, .accept)
    XCTAssertEqual(actions, [.neutralPads, .holdAwake(true)])
    XCTAssertEqual(m.state, .live(device: ipad))
    XCTAssertTrue(m.gamePaused)
    XCTAssertFalse(m.playing)
    _ = m.clientLeft(at: at(13))
    XCTAssertEqual(m.admit(device: tv, name: "Living Room", at: at(14)).1, [.holdAwake(true), .resumeGame, .requestKeyframe])
  }

  /// A playing session keeps the Mac: another device is busy, as before.
  func testAPlayingSessionKeepsTheMacBusy() {
    var m = liveWithGame()
    let (admission, actions) = m.admit(device: ipad, name: "iPad", at: at(1))
    XCTAssertEqual(admission, .busy(device: "Living Room"))
    XCTAssertEqual(actions, [])
    XCTAssertEqual(m.state, .live(device: tv))
  }

  /// A resuming session that replaces the same device's library session plays as a fresh resuming admission does.
  func testAResumingReplacementOfALibrarySessionPlaysAsAFreshOne() {
    var m = HostSessionModel()
    _ = m.admit(device: tv, name: "Living Room", resume: false, at: at(0))
    XCTAssertFalse(m.playing)
    _ = m.admit(device: tv, name: "Living Room", at: at(1))
    XCTAssertTrue(m.playing, "no game, nothing paused: a resuming session plays")
    XCTAssertEqual(m.gameStarted(at: at(2)), [], "not paused under it")
  }

  /// The game that the session played is gone (a quit, a crash, an end by the Host): the session is a library one now and
  /// another device gets in like it does into any library session.
  func testASessionStopsPlayingWhenItsGameIsGone() {
    var m = liveWithGame()
    XCTAssertTrue(m.playing)
    _ = m.gameExited(at: at(1))
    XCTAssertFalse(m.playing)
    let (admission, _) = m.admit(device: ipad, name: "iPad", at: at(2))
    XCTAssertEqual(admission, .accept)
    XCTAssertEqual(m.state, .live(device: ipad))
    // A launch from the live session plays again, and the game it starts is not paused under it.
    m.launchRequested(at: at(3))
    XCTAssertTrue(m.playing)
    XCTAssertEqual(m.gameStarted(at: at(4)), [])
    XCTAssertEqual(m.admit(device: tv, name: "Living Room", at: at(5)).0, .busy(device: "iPad"))
  }

  /// A session plays only while there is a game it plays: a resuming admission with no game is a library session, a
  /// `launch` makes it play, and a launch that fails takes that back.
  func testASessionPlaysOnlyWhileThereIsAGame() {
    var m = HostSessionModel()
    _ = m.admit(device: tv, name: "Living Room", gameExists: false, at: at(0))
    XCTAssertFalse(m.playing, "a resuming hello with no game to resume")
    m.launchRequested(at: at(1))
    XCTAssertTrue(m.playing)
    m.launchFailed()
    XCTAssertFalse(m.playing)
    XCTAssertEqual(m.admit(device: ipad, name: "iPad", gameExists: false, at: at(3)).0, .accept, "a library session gives way")
    // The same device reconnecting over its own session with the game gone is no player either.
    var n = HostSessionModel()
    _ = n.admit(device: tv, name: "Living Room", resume: false, at: at(0))
    _ = n.admit(device: tv, name: "Living Room", gameExists: false, at: at(1))
    XCTAssertFalse(n.playing)
  }

  /// A game that ends while paused owes nothing: the device that paused it is not resumed into a game that is gone.
  func testAGameThatEndsWhilePausedOwesNothing() {
    var m = pausedModel()
    _ = m.gameExited(at: at(11))
    XCTAssertFalse(m.gamePaused)
    let (_, actions) = m.admit(device: tv, name: "Living Room", at: at(12))
    XCTAssertEqual(actions, [.holdAwake(true)])
    XCTAssertEqual(m.gameStarted(at: at(13)), [], "the next game is not paused under its player")
  }

  func testNeutralAfterHalfSecond() {
    var m = liveWithGame()
    XCTAssertEqual(m.tick(at: at(0.4)), [])
    XCTAssertEqual(m.tick(at: at(0.6)), [.neutralPads])
    XCTAssertEqual(m.tick(at: at(0.7)), [])
    m.inputReceived(at: at(0.8))
    XCTAssertEqual(m.tick(at: at(1.4)), [.neutralPads])
  }

  /// A client that stalls for up to 9 s stays: the pads go neutral after 0.5 s (once), the session lives, nothing pauses.
  func testASilentClientStaysForNineSecondsAndIsDetachedAtTen() {
    XCTAssertEqual(HostSessionModel.defaultSilenceTimeout, 10)
    var m = liveWithGame()
    XCTAssertEqual(m.tick(at: at(0.6)), [.neutralPads])
    for s in stride(from: 1.0, through: 9.9, by: 0.1) { XCTAssertEqual(m.tick(at: at(s)), [], "at \(s) s") }
    XCTAssertEqual(m.state, .live(device: tv))
    XCTAssertFalse(m.gamePaused)
    XCTAssertEqual(m.tick(at: at(10.1)), [.neutralPads, .pauseGame])
    XCTAssertEqual(m.state, .detached)
    XCTAssertTrue(m.gamePaused)
  }

  /// A ping that arrives after a long stall keeps the session (the next silence starts from it).
  func testAPacketAfterAStallRestartsTheClock() {
    var m = liveWithGame()
    _ = m.tick(at: at(0.6))
    m.packetReceived(at: at(9))
    XCTAssertEqual(m.tick(at: at(18.9)), [])
    XCTAssertEqual(m.tick(at: at(19.1)), [.neutralPads, .pauseGame])
  }

  func testTheSilenceLimitCanBeInjected() {
    var m = HostSessionModel(silenceTimeout: 3)
    _ = m.admit(device: tv, name: "Living Room", at: at(0))
    _ = m.gameStarted(at: at(0))
    XCTAssertFalse(m.tick(at: at(2.9)).contains(.pauseGame))
    XCTAssertEqual(m.tick(at: at(3.1)), [.neutralPads, .pauseGame])
  }

  func testSameDeviceResumes() {
    var m = pausedModel()
    let (adm, actions) = m.admit(device: tv, name: "Living Room", at: at(10))
    XCTAssertEqual(adm, .accept)
    XCTAssertEqual(actions, [.holdAwake(true), .resumeGame, .requestKeyframe])
    XCTAssertFalse(m.gamePaused)
  }

  func testOtherDeviceTakesOverPaused() {
    var m = pausedModel()
    let (adm, actions) = m.admit(device: ipad, name: "iPad", at: at(10))
    XCTAssertEqual(adm, .accept)
    XCTAssertEqual(actions, [.holdAwake(true)])
    XCTAssertTrue(m.gamePaused)
    XCTAssertEqual(m.resumeRequested(at: at(11)), [.resumeGame, .requestKeyframe])
    XCTAssertEqual(m.resumeRequested(at: at(12)), [])
  }

  /// `resume` with no game plays nothing: the session stays a library session and another device is admitted over it.
  func testAResumeWithNoGameLeavesALibrarySession() {
    var m = HostSessionModel()
    _ = m.admit(device: tv, name: "Living Room", resume: false, gameExists: false, at: at(0))
    XCTAssertEqual(m.resumeRequested(gameExists: false, at: at(1)), [])
    XCTAssertFalse(m.playing)
    let (adm, _) = m.admit(device: ipad, name: "iPad", at: at(2))
    XCTAssertEqual(adm, .accept)
  }

  func testBusyWhileLive() {
    var m = liveWithGame()
    let (adm, actions) = m.admit(device: ipad, name: "iPad", at: at(1))
    XCTAssertEqual(adm, .busy(device: "Living Room"))
    XCTAssertEqual(actions, [])
    XCTAssertEqual(m.state, .live(device: tv))
  }

  func testAwakeGrace() {
    var m = liveWithGame()
    _ = m.clientLeft(at: at(0))
    XCTAssertEqual(m.tick(at: at(599)), [])
    XCTAssertEqual(m.tick(at: at(601)), [.holdAwake(false)])
    XCTAssertEqual(m.tick(at: at(700)), [])
  }

  func testNoPauseWithoutGame() {
    var m = HostSessionModel()
    _ = m.admit(device: tv, name: "Living Room", at: at(0))
    XCTAssertEqual(m.clientLeft(at: at(1)), [.neutralPads])
  }

  func testGameStartedAfterClientLeft() {
    var m = HostSessionModel()
    _ = m.admit(device: tv, name: "Living Room", at: at(0))
    _ = m.clientLeft(at: at(1))
    XCTAssertEqual(m.gameStarted(at: at(2)), [.pauseGame])
    XCTAssertTrue(m.gamePaused)
  }

  func testReconnectWhileLive() {
    var m = liveWithGame()
    let (adm, actions) = m.admit(device: tv, name: "Living Room", at: at(1))
    XCTAssertEqual(adm, .accept)
    XCTAssertEqual(actions, [.requestKeyframe])
  }
}
