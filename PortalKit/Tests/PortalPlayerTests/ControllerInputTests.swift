import XCTest
import os
import GameController
import PortalKit
@testable import PortalPlayer

@MainActor
final class ControllerInputTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[InputState]>(initialState: [])
        func add(_ s: InputState) { lock.withLock { $0.append(s) } }
        var all: [InputState] { lock.withLock { $0 } }
        func clear() { lock.withLock { $0.removeAll() } }
    }

    private func make(_ settings: ClientSettings = ClientSettings()) -> (ControllerInput, Recorder) {
        let r = Recorder()
        return (ControllerInput(settings: settings, send: { r.add($0) }), r)
    }

    private func settle(_ r: Recorder, timeout: TimeInterval = 5, until: (([InputState]) -> Bool)? = nil) async {
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1, stable = 0
        while Date() < deadline {
            let a = r.all
            if let until { if until(a) { return } }
            else if a.count == last { stable += 1; if stable >= 5 { return } } else { stable = 0 }
            last = a.count
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func background(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { c in DispatchQueue.global().async { body(); c.resume() } }
    }

    private func motion() -> MotionSample { MotionMapping.device(orientation: 1, acceleration: [0, 0, 1], rotation: [0, 0, 0]) }

    func testHandlersCallableOffMainActor() async {
        let (input, r) = make()
        input.start()
        let m = motion()
        await background {
            for i in 0..<100 {
                var s = PadSnapshot(); s.lx = Float(i) / 100
                input.padArrived(s, from: nil)
                input.deviceMotionArrived(m)
            }
        }
        await settle(r)
        XCTAssertFalse(r.all.isEmpty)
        input.stop()
    }

    func testPadEventsApplyInOrder() async {
        let (input, r) = make()
        input.start()
        r.clear()
        await background {
            for i in 0..<1000 {
                var s = PadSnapshot(); s.lx = Float(i) / 2000
                input.padArrived(s, from: nil)
            }
            var f = PadSnapshot(); f.lx = 1
            input.padArrived(f, from: nil)
        }
        await settle(r, until: { $0.last?.lx == 32767 })
        await settle(r)
        let lx = r.all.map(\.lx)
        XCTAssertEqual(lx.last, 32767)
        XCTAssertEqual(lx, lx.sorted(), "lx must never decrease")
        input.stop()
    }

    func testStopClearsState() async {
        let (input, r) = make()
        input.start()
        var s = PadSnapshot(); s.buttonA = true; s.lx = 1; s.ly = 1; s.rx = 1; s.ry = 1
        input.padArrived(s, from: nil)
        await settle(r, until: { $0.contains { $0.buttons != 0 } })
        XCTAssertTrue(r.all.contains { $0.buttons != 0 })
        input.stop()
        await settle(r)
        r.clear()
        input.start()
        input.deviceMotionArrived(motion())
        await settle(r, until: { !$0.isEmpty })
        let last = r.all.last
        XCTAssertNotNil(last)
        XCTAssertEqual(last?.buttons, 0)
        XCTAssertEqual([last?.lx, last?.ly, last?.rx, last?.ry], [0, 0, 0, 0])
        input.stop()
    }

    func testEventsAfterStopAreDropped() async {
        let (input, r) = make()
        input.start()
        input.stop()
        r.clear()
        await background {
            var s = PadSnapshot(); s.buttonA = true
            input.padArrived(s, from: nil)
            input.deviceMotionArrived(MotionMapping.device(orientation: 1, acceleration: [0, 0, 1], rotation: [0, 0, 0]))
        }
        await settle(r)
        XCTAssertTrue(r.all.isEmpty)
    }

    // MARK: menu chord, sendCurrent, unused motion

    private func both() -> PadSnapshot { var s = PadSnapshot(); s.menu = true; s.options = true; return s }

    func testMenuChordFiresOnce() async throws {
        let (input, r) = make()
        var calls = 0
        input.onMenuChord = { calls += 1 }
        input.start()
        input.padArrived(both(), from: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(calls, 1)
        input.padArrived(both(), from: nil)  // still held: no second call
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(calls, 1, "fires once per hold")
        let plusMinus = PadButtons.plus.union(.minus).rawValue
        XCTAssertTrue(r.all.contains { $0.buttons == plusMinus }, "the game still receives both buttons")
        input.padArrived(PadSnapshot(), from: nil)
        try await Task.sleep(for: .milliseconds(100))
        input.padArrived(both(), from: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(calls, 2, "released and held again")
        input.padArrived(PadSnapshot(), from: nil)
        var one = PadSnapshot(); one.menu = true
        input.padArrived(one, from: nil)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(calls, 2, "one button alone")
        input.stop()
    }

    func testMenuChordShortHoldAndOffFireNothing() async throws {
        let (input, _) = make()
        var calls = 0
        input.onMenuChord = { calls += 1 }
        input.start()
        input.padArrived(both(), from: nil)
        try await Task.sleep(for: .milliseconds(200))
        input.padArrived(PadSnapshot(), from: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(calls, 0, "released before 0.5 s")
        input.stop()
        var off = ClientSettings(); off.menuChord = .off
        let (quiet, r) = make(off)
        quiet.onMenuChord = { calls += 1 }
        quiet.start()
        quiet.padArrived(both(), from: nil)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(calls, 0, "off")
        XCTAssertTrue(r.all.contains { $0.buttons != 0 }, "off still reaches the game")
        quiet.stop()
    }

    func testSendCurrentRepeatsHeldState() async {
        let (input, r) = make()
        input.start()
        var s = PadSnapshot(); s.buttonA = true
        input.padArrived(s, from: nil)
        await settle(r, until: { $0.contains { $0.buttons != 0 } })
        r.clear()
        input.sendCurrent()
        XCTAssertEqual(r.all.count, 1)
        XCTAssertNotEqual(r.all.first?.buttons, 0)
        input.stop()
    }

    func testUnusedDeviceMotionSendsNothing() async {
        var never = ClientSettings(); never.deviceMotion = .never
        let (input, r) = make(never)
        input.start()
        r.clear()
        input.deviceMotionArrived(motion())
        await settle(r)
        XCTAssertTrue(r.all.isEmpty, "motion mode never: a device sample is not sent")
        input.stop()
        let (auto, ra) = make()
        auto.start()
        auto.controllerMotionArrived(MotionMapping.controller(acceleration: [1, 0, 0], rotation: [0, 1, 0]), from: nil)
        await settle(ra)
        ra.clear()
        auto.deviceMotionArrived(motion())
        await settle(ra)
        XCTAssertTrue(ra.all.isEmpty, "auto with a live controller sensor: a device sample is not sent")
        auto.stop()
    }

    // MARK: the in-play menu (open: neutral once, B goes back, Home toggles)

    /// One pad snapshot, applied before the next (the inbox keeps only the newest of a burst).
    private func feed(_ input: ControllerInput, _ s: PadSnapshot) {
        input.padArrived(s, from: nil)
        input.drainNow()
    }

    private func pressed(a: Bool = false, b: Bool = false, home: Bool = false) -> PadSnapshot {
        var s = PadSnapshot(); s.buttonA = a; s.buttonB = b; s.home = home; return s
    }

    private func isNeutral(_ i: InputState) -> Bool { i.buttons == 0 && i.lx == 0 && i.ly == 0 && i.rx == 0 && i.ry == 0 }

    // MARK: a sheet over the menu (the play screen's wiring: `menuOpen` is the one cover rule)

    /// The play screen's covers, wired as `PlayView` does on every platform: the routes go to `PlayOverlays` and
    /// `menuOpen` follows `PlayRoute.covered`.
    @MainActor private final class PlayScreen {
        var overlays = PlayOverlays()
        let input: ControllerInput
        init(_ input: ControllerInput) {
            self.input = input
            input.onBack = { [unowned self] in overlays.back(); sync() }
            input.onMenuToggle = { [unowned self] in overlays.toggle(allowed: true); sync() }
            input.onMenuChord = { [unowned self] in overlays.toggle(allowed: true); sync() }
        }
        func sync() { input.menuOpen = overlays.covers(trouble: .none, startingCard: false) }
    }

    private func pressedA(b: Bool = false, home: Bool = false) -> PadSnapshot { pressed(a: true, b: b, home: home) }

    /// Menu, then the options sheet, then B: the sheet closes and the menu stays; A reaches nothing until the menu too closes.
    func testBWithTheOptionsSheetUpClosesTheSheetOnlyAndTheGameGetsNothing() {
        let (input, r) = make()
        let screen = PlayScreen(input)
        input.start()
        feed(input, pressed())
        feed(input, pressed(home: true)); feed(input, pressed())
        screen.overlays.sheet = true; screen.sync()
        r.clear()
        feed(input, pressed(b: true)); feed(input, pressed())
        XCTAssertEqual(screen.overlays, PlayOverlays(menu: true, sheet: false))
        feed(input, pressedA()); feed(input, pressed())
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "the game got input under the menu: \(r.all)")
        feed(input, pressed(b: true)); feed(input, pressed())
        XCTAssertEqual(screen.overlays, PlayOverlays())
        r.clear()
        feed(input, pressedA())
        XCTAssertTrue(r.all.contains { $0.buttons != 0 }, "nothing covers: A is the game's")
        input.stop()
    }

    /// The sheet up over the menu, then Home: the sheet closes, the menu stays, the game still gets only neutral.
    func testHomeWithTheSheetUpClosesTheSheetOnly() {
        let (input, r) = make()
        let screen = PlayScreen(input)
        input.start()
        feed(input, pressed())
        screen.overlays = PlayOverlays(menu: true, sheet: true); screen.sync()
        r.clear()
        feed(input, pressed(home: true)); feed(input, pressed())
        XCTAssertEqual(screen.overlays, PlayOverlays(menu: true, sheet: false))
        feed(input, pressedA()); feed(input, pressed())
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "the game got input under the menu: \(r.all)")
        feed(input, pressed(home: true)); feed(input, pressed())
        XCTAssertEqual(screen.overlays, PlayOverlays())
        r.clear()
        feed(input, pressedA())
        XCTAssertTrue(r.all.contains { $0.buttons != 0 })
        input.stop()
    }

    /// The sheet up over the menu, then the chord: the sheet closes, the menu stays; neutral until nothing covers.
    func testTheChordWithTheSheetUpClosesTheSheetOnly() async throws {
        let (input, r) = make()
        let screen = PlayScreen(input)
        input.start()
        feed(input, pressed())
        screen.overlays = PlayOverlays(menu: true, sheet: true); screen.sync()
        r.clear()
        feed(input, both())
        try await Task.sleep(nanoseconds: ControllerInput.menuChordHoldNs + 200_000_000)
        feed(input, PadSnapshot())
        XCTAssertEqual(screen.overlays, PlayOverlays(menu: true, sheet: false))
        feed(input, pressedA()); feed(input, pressed())
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "the game got input under the menu: \(r.all)")
        feed(input, pressed(b: true)); feed(input, pressed())
        XCTAssertEqual(screen.overlays, PlayOverlays())
        r.clear()
        feed(input, pressedA())
        XCTAssertTrue(r.all.contains { $0.buttons != 0 })
        input.stop()
    }

    func testWhileTheMenuIsOpenAIsNotForwardedAndOneNeutralInputIsSent() {
        let (input, r) = make()
        input.start()
        feed(input, pressed())
        r.clear()
        input.menuOpen = true
        XCTAssertEqual(r.all.count, 1, "one neutral input at once")
        XCTAssertTrue(r.all.first.map(isNeutral) ?? false)
        feed(input, pressed(a: true))
        feed(input, pressed())
        feed(input, pressed(a: true))
        input.deviceMotionArrived(motion())
        input.drainNow()
        XCTAssertEqual(r.all.count, 1, "nothing else while open: \(r.all)")
        feed(input, pressed())
        r.clear()
        input.menuOpen = false
        r.clear()
        feed(input, pressed(a: true))
                XCTAssertTrue(r.all.contains { $0.buttons != 0 }, "after the menu closes A is forwarded")
        input.stop()
    }

    func testBCallsOnBackOnceAndIsNotForwardedAndIsNotStuckOnClose() {
        let (input, r) = make()
        var backs = 0
        input.onBack = { backs += 1 }
        input.start()
        feed(input, pressed())
        input.menuOpen = true
        r.clear()
        feed(input, pressed(b: true))
        feed(input, pressed(b: true))  // held: no second call
        XCTAssertEqual(backs, 1)
        XCTAssertEqual(r.all.count, 0, "B is not forwarded")
        input.menuOpen = false  // the model closes the menu on B
        r.clear()
        feed(input, pressed(b: true))  // B is still down
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "the B that closed the menu never reaches the game: \(r.all)")
        feed(input, pressed())
        feed(input, pressed(b: true))  // a new press
                XCTAssertTrue(r.all.contains { $0.buttons != 0 }, "a new B press is the game's")
        XCTAssertEqual(backs, 1, "B is the menu's only while it is open")
        input.stop()
    }

    func testHomeTogglesOnceWhetherOpenOrClosedAndNeverReachesSend() {
        let (input, r) = make()
        var toggles = 0
        input.onMenuToggle = { toggles += 1 }
        input.start()
        feed(input, pressed())
        r.clear()
        feed(input, pressed(home: true))
        feed(input, pressed(home: true))  // held
        XCTAssertEqual(toggles, 1)
        feed(input, pressed())
        feed(input, pressed(home: true))
        XCTAssertEqual(toggles, 2, "released and pressed again")
        input.menuOpen = true
        feed(input, pressed())
        feed(input, pressed(home: true))
        XCTAssertEqual(toggles, 3, "open: Home toggles too")
        input.menuOpen = false
        r.clear()
        feed(input, pressed())
        feed(input, pressed(home: true))
        feed(input, pressed())
        XCTAssertFalse(r.all.contains { $0.buttons != 0 }, "Home is never a game button")
        XCTAssertEqual(toggles, 4)
        input.stop()
    }

    func testAControllerWithoutHomeTogglesNothing() {
        let (input, r) = make()
        var toggles = 0
        input.onMenuToggle = { toggles += 1 }
        input.start()
        feed(input, pressed(a: true))
                XCTAssertEqual(toggles, 0)
        XCTAssertTrue(r.all.contains { $0.buttons != 0 })
        input.stop()
    }

    func testSendCurrentWhileTheMenuIsOpenSendsNeutral() {
        let (input, r) = make()
        input.start()
        feed(input, pressed(a: true))
                input.menuOpen = true
        r.clear()
        input.sendCurrent()
        XCTAssertEqual(r.all.count, 1)
        XCTAssertTrue(r.all.first.map(isNeutral) ?? false)
        input.stop()
    }

    /// The controller goes away while the menu is open: the game is sent neutral; nothing is stuck once the menu closes.
    func testAControllerLostWhileTheMenuIsOpenLeavesNothingStuck() {
        let (input, r) = make()
        input.start()
        feed(input, pressed(a: true))
        XCTAssertTrue(r.all.contains { $0.buttons != 0 })
        input.menuOpen = true
        r.clear()
        input.controllerLost()
        XCTAssertTrue(r.all.allSatisfy(isNeutral) && !r.all.isEmpty, "neutral to the game: \(r.all)")
        input.menuOpen = false
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "nothing stuck after the menu closes: \(r.all)")
        XCTAssertTrue(r.all.last.map(isNeutral) ?? false)
        r.clear()
        feed(input, pressed(a: true))  // another controller's A is the game's
        XCTAssertTrue(r.all.contains { $0.buttons != 0 })
        input.stop()
    }

    /// The session ends (the input stops) under the open menu: nothing is sent afterwards, and the next session starts fresh.
    func testTheInputStoppingUnderTheOpenMenuSendsNothingAndTheNextStartIsFresh() {
        let (input, r) = make()
        input.start()
        feed(input, pressed(a: true))
        input.menuOpen = true
        input.stop()
        r.clear()
        feed(input, pressed(a: true))  // after stop: dropped
        XCTAssertTrue(r.all.isEmpty, "nothing after stop: \(r.all)")
        input.menuOpen = false  // the view resets it
        XCTAssertTrue(r.all.isEmpty, "a stopped input sends nothing on a menu change")
        input.start()
        r.clear()
        feed(input, pressed(a: true))
        XCTAssertTrue(r.all.contains { $0.buttons != 0 }, "the next session: A is the game's")
        input.stop()
    }

    /// The chord closes the menu while Menu and Options are still held: neither reaches the game until released.
    func testTheChordClosingTheMenuWithBothButtonsHeldReachesTheGameOnlyAfterTheRelease() {
        let (input, r) = make()
        input.start()
        feed(input, PadSnapshot())
        input.menuOpen = true
        feed(input, both())
        r.clear()
        input.menuOpen = false  // the chord's close, both still down
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "at the close: \(r.all)")
        feed(input, both())
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "still held: \(r.all)")
        feed(input, PadSnapshot())
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "the release: \(r.all)")
        r.clear()
        feed(input, both())  // pressed again: now the game's
        let plusMinus = PadButtons.plus.union(.minus).rawValue
        XCTAssertTrue(r.all.contains { $0.buttons == plusMinus }, "a new press reaches the game: \(r.all)")
        input.stop()
    }

    // MARK: the on-screen controller

    private func touch(_ buttons: PadButtons = [], lx: Int32 = 0) -> TouchOutput {
        var t = TouchOutput.neutral; t.buttons = buttons; t.lx = lx; return t
    }

    func testATouchOutputIsOneSendForPlayerZero() {
        let (input, r) = make()
        input.start()
        r.clear()
        input.touchArrived(touch([.a], lx: 500))
        input.drainNow()
        XCTAssertEqual(r.all.count, 1)
        XCTAssertEqual(r.all.first?.player, 0)
        XCTAssertEqual(r.all.first?.buttons, PadButtons.a.rawValue)
        XCTAssertEqual(r.all.first?.lx, 500)
        input.touchArrived(touch([.a], lx: 500))  // the same again is no news
        input.drainNow()
        XCTAssertEqual(r.all.count, 1)
        input.stop()
    }

    func testATouchWhileTheMenuIsOpenIsNotSentAndNothingIsHeldAfterwards() {
        let (input, r) = make()
        input.start()
        input.touchArrived(touch([.a]))
        input.drainNow()
        input.menuOpen = true
        r.clear()
        input.touchArrived(touch([.b]))  // a finger that landed as the menu opened
        input.drainNow()
        XCTAssertTrue(r.all.isEmpty, "nothing while open: \(r.all)")
        input.touchArrived(touch())  // the view released everything as the menu opened
        input.drainNow()
        input.menuOpen = false
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "nothing stuck after the menu closes: \(r.all)")
        XCTAssertTrue(r.all.last.map(isNeutral) ?? false)
        input.stop()
    }

    func testOpeningTheMenuForgetsTheTouchWithoutTheViewsNeutral() {
        let (input, r) = make()
        input.start()
        input.touchArrived(touch([.a], lx: 900)); input.drainNow()
        XCTAssertEqual(r.all.last?.buttons, PadButtons.a.rawValue)
        input.menuOpen = true
        input.menuOpen = false  // the view never sent its neutral
        XCTAssertTrue(r.all.last.map(isNeutral) ?? false, "the finger is not held again at close: \(String(describing: r.all.last))")
        input.stop()
    }

    func testAFingerLandingAfterTheMenuOpenedIsNeverHeldAtClose() {
        let (input, r) = make()
        input.start()
        input.menuOpen = true
        input.touchArrived(touch([.b], lx: 700)); input.drainNow()  // and never lifted before the close
        input.menuOpen = false
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "\(r.all)")
        input.stop()
    }

    func testStopSendsNeutralLastSoNothingStaysHeldOnTheMac() {
        let (input, r) = make()
        input.start()
        input.touchArrived(touch([.a])); input.drainNow()
        XCTAssertFalse(r.all.last.map(isNeutral) ?? true, "a button is held before the stop")
        input.stop()
        XCTAssertTrue(r.all.last.map(isNeutral) ?? false, "the last input sent is neutral: \(String(describing: r.all.last))")
        let n = r.all.count
        input.stop()
        XCTAssertEqual(r.all.count, n, "a second stop sends nothing")
    }

    func testATouchHeldAcrossAStopAndAnOpenMenuIsGoneAtTheNextClose() {
        let (input, r) = make()
        input.start()
        input.touchArrived(touch([.a])); input.drainNow()
        input.stop()
        input.menuOpen = true  // not started: nothing runs
        input.start()
        input.menuOpen = false
        XCTAssertTrue(r.all.last.map(isNeutral) ?? false, "\(String(describing: r.all.last))")
        input.stop()
    }

    func testTheInputStoppingForgetsTheTouches() {
        let (input, r) = make()
        input.start()
        input.touchArrived(touch([.a])); input.drainNow()
        input.stop()
        input.start()
        r.clear()
        input.sendCurrent()
        XCTAssertTrue(r.all.allSatisfy(isNeutral), "the next start is fresh: \(r.all)")
        input.stop()
    }

    func testPresenceIsReportedOnAdoptAndOnRelease() {
        let (input, _) = make()
        var seen: [Bool] = []
        input.presenceChanged = { seen.append($0) }
        input.start()
        input.notePresence(true)
        input.notePresence(true)  // no change, no report
        input.controllerLost()
        input.controllerLost()
        XCTAssertEqual(seen, [true, false])
        input.notePresence(true)
        input.stop()
        XCTAssertEqual(seen, [true, false, true, false], "the input stopping is a release")
    }

    /// The Siri Remote is a micro gamepad: a controller with no extended profile is never adopted as the game controller.
    func testAControllerWithoutTheExtendedProfileIsNotAGameController() {
        let remote = GCController()  // no profiles at all, like the remote's own (micro) one to this check
        XCTAssertNil(remote.extendedGamepad)
        XCTAssertFalse(ControllerInput.isGameController(remote))
        let (input, _) = make()
        var seen: [Bool] = []
        input.presenceChanged = { seen.append($0) }
        input.start()
        XCTAssertEqual(seen, [], "no controller in use, so no presence")
        input.stop()
    }
}
