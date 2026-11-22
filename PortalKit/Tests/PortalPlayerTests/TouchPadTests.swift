import XCTest
import PortalKit
@testable import PortalPlayer

/// The on-screen controller's geometry, ownership and outputs -> .claude/client.md § input
final class TouchPadTests: XCTestCase {
    private let flat = TouchRect(x: 0, y: 0, width: 932, height: 430)
    private let none = TouchInsets(top: 0, left: 0, bottom: 0, right: 0)

    private func pad(_ layout: TouchLayout = .flat) -> TouchPad {
        TouchPad(geometry: TouchGeometry(bounds: flat, insets: none), layout: layout)
    }
    private func P(_ x: Double, _ y: Double) -> TouchPoint { TouchPoint(x, y) }
    private func shape(_ pad: TouchPad, _ b: PadButtons) -> TouchShape? { pad.shapes().first { $0.button == b } }
    private func near(_ a: TouchPoint, _ x: Double, _ y: Double, _ tol: Double = 0.05, line: UInt = #line) {
        XCTAssertEqual(a.x, x, accuracy: tol, line: line); XCTAssertEqual(a.y, y, accuracy: tol, line: line)
    }

    // MARK: geometry

    func testUnit() {
        XCTAssertEqual(TouchGeometry(bounds: flat, insets: none).u, 1.0, accuracy: 1e-9)
        XCTAssertEqual(TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 1194, height: 834), insets: none).u, 1.3, accuracy: 1e-9)
        XCTAssertEqual(TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 400, height: 215), insets: none).u, 0.5, accuracy: 1e-9)
    }

    func testTwoDShapes() throws {
        let p = pad()
        near(try XCTUnwrap(shape(p, .zl)).centre, 44, 40); XCTAssertEqual(try XCTUnwrap(shape(p, .zl)).radius, 26)
        near(try XCTUnwrap(shape(p, .zr)).centre, 888, 40)
        near(try XCTUnwrap(shape(p, .l)).centre, 44, 108); XCTAssertEqual(try XCTUnwrap(shape(p, .l)).radius, 24)
        near(try XCTUnwrap(shape(p, .r)).centre, 888, 108)
        XCTAssertEqual(try XCTUnwrap(shape(p, .minus)).rect, TouchRect(x: 389, y: 8, width: 50, height: 28))
        XCTAssertEqual(try XCTUnwrap(shape(p, .plus)).rect, TouchRect(x: 493, y: 8, width: 50, height: 28))
        for (b, x, y) in [(PadButtons.a, 901.0, 348.0), (.b, 851, 398), (.x, 851, 298), (.y, 801, 348)] {
            let s = try XCTUnwrap(shape(p, b)); near(s.centre, x, y); XCTAssertEqual(s.radius, 27)
        }
        XCTAssertEqual(p.ring.centre, P(81, 348)); XCTAssertEqual(p.ring.radius, 77); XCTAssertEqual(p.ring.knobRadius, 30)
        XCTAssertEqual(p.gear.centre, P(466, 22)); XCTAssertEqual(p.gear.radius, 15)
        XCTAssertEqual(p.shapes().count, 10)
        XCTAssertTrue(p.shapes().allSatisfy { $0.button != nil })
    }

    func testDropsPointToTheNearTopCorner() throws {
        let p = pad()
        XCTAssertEqual(try XCTUnwrap(shape(p, .zl)).kind, .drop(tipAngle: -3 * Double.pi / 4))
        XCTAssertEqual(try XCTUnwrap(shape(p, .zr)).kind, .drop(tipAngle: -Double.pi / 4))
        XCTAssertEqual(try XCTUnwrap(shape(p, .minus)).kind, .pill)
        XCTAssertEqual(try XCTUnwrap(shape(p, .a)).kind, .circle)
    }

    func testLabelSizes() throws {
        let p = pad(.full)
        XCTAssertEqual(try XCTUnwrap(shape(p, .a)).labelSize, 20)
        XCTAssertEqual(try XCTUnwrap(shape(p, .zl)).labelSize, 16)
        XCTAssertEqual(try XCTUnwrap(shape(p, .stickL)).labelSize, 13)
        XCTAssertEqual(try XCTUnwrap(shape(p, .minus)).labelSize, 18)
        XCTAssertEqual(try XCTUnwrap(shape(p, .a)).label, "A")
        XCTAssertNil(try XCTUnwrap(shape(p, .up)).label)
    }

    func testThreeDAddsTheDpadAndClicks() throws {
        let p = pad(.full)
        XCTAssertEqual(p.shapes().count, 16)
        for b: PadButtons in [.up, .down, .left, .right] { XCTAssertNotNil(shape(p, b)) }
        near(try XCTUnwrap(shape(p, .stickL)).centre, 102, 40); XCTAssertEqual(try XCTUnwrap(shape(p, .stickL)).radius, 17)
        near(try XCTUnwrap(shape(p, .stickR)).centre, 830, 40)
        for b: PadButtons in [.up, .down, .left, .right] {
            let s = try XCTUnwrap(shape(p, b)); near(s.centre, 231, 366)
            guard case .arm = s.kind else { return XCTFail("not an arm") }
        }
    }

    func testScaledAndInsetShapes() throws {
        let big = TouchPad(geometry: TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 1194, height: 834), insets: none), layout: .flat)
        let zl = try XCTUnwrap(shape(big, .zl)); near(zl.centre, 57.2, 52); XCTAssertEqual(zl.radius, 33.8, accuracy: 1e-9)
        near(try XCTUnwrap(shape(big, .a)).centre, 1153.7, 727.4)
        let inset = TouchPad(geometry: TouchGeometry(bounds: flat, insets: TouchInsets(top: 0, left: 59, bottom: 21, right: 59)), layout: .flat)
        near(try XCTUnwrap(shape(inset, .zl)).centre, 103, 40)
        near(try XCTUnwrap(shape(inset, .zr)).centre, 829, 40)
        near(try XCTUnwrap(shape(inset, .a)).centre, 871.5, 327)
        near(inset.ring.centre, 110.5, 327)
        near(inset.gear.centre, 466, 22)
    }

    // MARK: ownership and sliding

    func testAShoulderIsHeldWhereTheFingerLanded() {
        var p = pad()
        var c = p.begin(1, at: P(44, 40))
        XCTAssertEqual(p.pressed, [.zl]); XCTAssertTrue(c.haptic); XCTAssertTrue(c.output)
        c = p.move(1, to: P(44, 108))
        XCTAssertEqual(p.pressed, [.zl]); XCTAssertFalse(c.haptic)
        c = p.end(1)
        XCTAssertEqual(p.pressed, []); XCTAssertTrue(c.output)
    }

    func testTwoFingersOnDifferentAndOnTheSameKey() {
        var p = pad()
        _ = p.begin(1, at: P(44, 40)); _ = p.begin(2, at: P(888, 40))
        XCTAssertEqual(p.pressed, [.zl, .zr])
        _ = p.end(1)
        XCTAssertEqual(p.pressed, [.zr])
        var q = pad()
        _ = q.begin(1, at: P(44, 40)); _ = q.begin(2, at: P(50, 45))
        _ = q.end(1)
        XCTAssertEqual(q.pressed, [.zl])
        _ = q.end(2)
        XCTAssertEqual(q.pressed, [])
    }

    func testTheDiamondSlides() {
        var p = pad()
        _ = p.begin(1, at: P(901, 348))
        XCTAssertEqual(p.pressed, [.a])
        var c = p.move(1, to: P(851, 398))
        XCTAssertEqual(p.pressed, [.b]); XCTAssertTrue(c.haptic)
        _ = p.move(1, to: P(876, 373))
        XCTAssertEqual(p.pressed, [])
        c = p.move(1, to: P(901, 348))
        XCTAssertEqual(p.pressed, [.a]); XCTAssertTrue(c.haptic)
    }

    func testADiamondTouchLandingBetweenKeysIsStillOwned() {
        var p = pad()
        let c = p.begin(1, at: P(851, 348))
        XCTAssertEqual(p.pressed, []); XCTAssertFalse(c.output)
        _ = p.move(1, to: P(901, 348))
        XCTAssertEqual(p.pressed, [.a])
    }

    func testMinusAndTheGearShareTheTopMiddle() {
        var p = pad()
        _ = p.begin(1, at: P(414, 22))
        XCTAssertEqual(p.pressed, [.minus])
        XCTAssertTrue(p.gearTakes(P(466, 22)))
        XCTAssertTrue(p.gearTakes(P(447, 22)))
        XCTAssertFalse(p.gearTakes(P(441, 22)))
        var q = pad()
        _ = q.begin(1, at: P(441, 22))
        XCTAssertEqual(q.pressed, [.minus])
        XCTAssertFalse(pad().gearTakes(P(300, 200)))
    }

    func testTheNearerOfTheGearAndAKeyWins() {
        var p = pad()
        XCTAssertTrue(p.gearTakes(P(446, 22)), "nearer the gear than the key")
        XCTAssertFalse(p.gearTakes(P(443, 22)), "nearer the key")
        _ = p.begin(1, at: P(443, 22))
        XCTAssertEqual(p.pressed, [.minus])
        var q = pad()
        let c = q.begin(1, at: P(446, 22))
        XCTAssertEqual(q.pressed, [], "the gear's touch is not the controller's"); XCTAssertFalse(c.output)
    }

    func testWithTheControlsHiddenTheGearTakesItsWholeCircle() {
        let p = pad()
        XCTAssertFalse(p.gearTakes(P(443, 22)))
        XCTAssertTrue(p.gearTakes(P(443, 22), controlsShown: false))
        XCTAssertFalse(p.gearTakes(P(441, 22), controlsShown: false), "outside its circle")
    }

    func testATouchOnTheGearHoldsNothing() {
        var p = pad()
        let c = p.begin(1, at: P(466, 22))
        XCTAssertEqual(p.pressed, []); XCTAssertFalse(c.output)
    }

    func testATouchOnNothingChangesNothing() {
        var p = pad()
        let c = p.begin(1, at: P(500, 250))
        XCTAssertEqual(c, TouchChange(output: false, visual: false, haptic: false))
        XCTAssertEqual(p.end(1), TouchChange(output: false, visual: false, haptic: false))
    }

    // MARK: stick

    func testTheStickReadsTiltFromTheRingCentre() {
        var p = pad()
        var c = p.begin(1, at: P(81, 348))
        XCTAssertTrue(c.haptic)
        _ = p.move(1, to: P(142.6, 348))
        XCTAssertEqual(p.output.lx, 32767); XCTAssertEqual(p.output.ly, 0)
        _ = p.move(1, to: P(88.6, 348))
        XCTAssertEqual(p.output.lx, 0)
        _ = p.move(1, to: P(115.65, 348))
        XCTAssertEqual(Double(p.output.lx), 16384, accuracy: 1)
        _ = p.move(1, to: P(81, 286.4))
        XCTAssertEqual(p.output.ly, 32767)
        c = p.move(1, to: P(281, 348))
        XCTAssertEqual(p.output.lx, 32767); XCTAssertEqual(p.knob, P(77, 0)); XCTAssertTrue(c.output)
        c = p.end(1)
        XCTAssertEqual(p.output.lx, 0); XCTAssertEqual(p.knob, P(0, 0)); XCTAssertTrue(c.output); XCTAssertTrue(c.visual)
    }

    func testTheStickGrabAndASecondFinger() {
        var p = pad()
        _ = p.begin(1, at: P(190, 350))
        XCTAssertEqual(p.knob, P(0, 0)); XCTAssertEqual(p.ring.centre, P(81, 348))
        _ = p.move(1, to: P(142.6, 348))
        XCTAssertEqual(p.output.lx, 0, "not a stick")
        var q = pad()
        _ = q.begin(1, at: P(150, 350))
        let before = q.output
        let c = q.begin(2, at: P(100, 340))
        XCTAssertEqual(q.output, before); XCTAssertFalse(c.output)
        XCTAssertEqual(q.knob, P(69, 2))
    }

    // MARK: 3D

    func testTheCameraIsTheRightThirdOfTheScreen() {
        var p = pad(.full)
        _ = p.begin(1, at: P(621, 200))
        XCTAssertEqual(p.output, .neutral)
        _ = p.move(1, to: P(700, 200))
        XCTAssertEqual(p.output.rx, 0)
        _ = p.end(1)
        var q = pad(.full)
        _ = q.begin(1, at: P(622, 200))
        _ = q.move(1, to: P(670, 200))
        XCTAssertNotEqual(q.output.rx, 0, "held from where it landed")
    }

    func testTheCameraStickFollowsTheFinger() {
        var p = pad(.full)
        _ = p.begin(1, at: P(700, 200))
        _ = p.move(1, to: P(748, 200)); XCTAssertEqual(p.output.rx, 32767)
        _ = p.move(1, to: P(700, 152)); XCTAssertEqual(p.output.ry, 32767)
        _ = p.move(1, to: P(800, 200)); XCTAssertEqual(p.output.rx, 32767)
        _ = p.move(1, to: P(740, 200)); XCTAssertEqual(p.output.rx, 0)
        _ = p.move(1, to: P(700, 200)); XCTAssertEqual(Double(p.output.rx), -26526, accuracy: 1)
        XCTAssertEqual(p.knob, P(0, 0), "the camera stick is not drawn")
        _ = p.end(1)
        XCTAssertEqual(p.output, .neutral)
    }

    func testASecondFingerInTheCameraAreaChangesNothing() {
        var p = pad(.full)
        _ = p.begin(1, at: P(700, 200))
        _ = p.move(1, to: P(748, 200))
        let before = p.output
        let c = p.begin(2, at: P(800, 250))
        XCTAssertEqual(p.output, before); XCTAssertFalse(c.output)
        _ = p.move(2, to: P(900, 250))
        XCTAssertEqual(p.output, before)
    }

    func testTheDiamondInsideTheRightThirdIsTheDiamond() {
        var p = pad(.full)
        _ = p.begin(1, at: P(901, 348))
        XCTAssertEqual(p.pressed, [.a])
    }

    func testTheCameraDoesNotExistInTwoD() {
        var p = pad()
        let c = p.begin(1, at: P(700, 200))
        XCTAssertFalse(c.output)
        _ = p.move(1, to: P(748, 200))
        XCTAssertEqual(p.output, .neutral)
    }

    func testTheDpadHasEightDirections() {
        var p = pad(.full)
        _ = p.begin(1, at: P(261, 336)); XCTAssertEqual(p.pressed, [.right, .up])
        _ = p.end(1)
        _ = p.begin(1, at: P(231, 336)); XCTAssertEqual(p.pressed, [.up])
        _ = p.end(1)
        _ = p.begin(1, at: P(236, 366)); XCTAssertEqual(p.pressed, [])
        _ = p.end(1)
        _ = p.begin(1, at: P(261, 336)); _ = p.move(1, to: P(201, 336))
        XCTAssertEqual(p.pressed, [.left, .up])
        _ = p.move(1, to: P(231, 396)); XCTAssertEqual(p.pressed, [.down])
        _ = p.move(1, to: P(201, 396)); XCTAssertEqual(p.pressed, [.left, .down])
    }

    func testTheStickWinsNearThePadInThreeD() {
        var p = pad(.full)
        _ = p.begin(1, at: P(150, 350))
        XCTAssertEqual(p.pressed, [])
        _ = p.move(1, to: P(150 + 100, 350))
        XCTAssertGreaterThan(p.output.lx, 0, "the stick, not the D-pad")
    }

    func testTheClicksAreKeysInThreeDOnly() {
        var p = pad(.full)
        _ = p.begin(1, at: P(102, 40)); XCTAssertEqual(p.pressed, [.stickL])
        _ = p.begin(2, at: P(830, 40)); XCTAssertEqual(p.pressed, [.stickL, .stickR])
        var q = pad()
        _ = q.begin(1, at: P(102, 40)); XCTAssertEqual(q.pressed, [])
    }

    // MARK: nothing stays held

    func testAnotherSizeReleasesEverything() {
        var p = pad()
        _ = p.begin(1, at: P(44, 40)); _ = p.begin(2, at: P(901, 348)); _ = p.begin(3, at: P(81, 348)); _ = p.move(3, to: P(142.6, 348))
        XCTAssertNotEqual(p.output, .neutral)
        let c = p.setGeometry(TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 800, height: 400), insets: none))
        XCTAssertEqual(p.output, .neutral); XCTAssertTrue(c.output); XCTAssertEqual(p.knob, P(0, 0))
        // the old fingers stay owned by nothing: their later moves and ends do nothing
        XCTAssertEqual(p.move(3, to: P(100, 300)), TouchChange(output: false, visual: false, haptic: false))
        XCTAssertEqual(p.end(1), TouchChange(output: false, visual: false, haptic: false))
        XCTAssertEqual(p.output, .neutral)
    }

    func testTheSameSizeChangesNothing() {
        var p = pad()
        _ = p.begin(1, at: P(44, 40))
        let c = p.setGeometry(TouchGeometry(bounds: flat, insets: none))
        XCTAssertEqual(c, TouchChange(output: false, visual: false, haptic: false))
        XCTAssertEqual(p.pressed, [.zl])
    }

    func testAnotherLayoutReleasesAndReshapes() {
        var p = pad()
        _ = p.begin(1, at: P(44, 40))
        let c = p.setLayout(.full)
        XCTAssertEqual(p.pressed, []); XCTAssertTrue(c.output)
        XCTAssertEqual(p.shapes().count, 16)
        XCTAssertEqual(p.setLayout(.full), TouchChange(output: false, visual: false, haptic: false))
    }

    func testReleaseAllAndACancelledTouch() {
        var p = pad(.full)
        _ = p.begin(1, at: P(44, 40)); _ = p.begin(2, at: P(700, 200)); _ = p.move(2, to: P(748, 200))
        let c = p.releaseAll()
        XCTAssertEqual(p.output, .neutral); XCTAssertTrue(c.output)
        XCTAssertEqual(p.releaseAll(), TouchChange(output: false, visual: false, haptic: false))
        // a cancelled touch is an end
        var q = pad()
        _ = q.begin(1, at: P(901, 348)); _ = q.begin(2, at: P(81, 348)); _ = q.move(2, to: P(142.6, 348))
        _ = q.end(1); _ = q.end(2)
        XCTAssertEqual(q.output, .neutral)
    }

    func testAnEndWithoutABeginIsHarmless() {
        var p = pad()
        XCTAssertEqual(p.end(9), TouchChange(output: false, visual: false, haptic: false))
        XCTAssertEqual(p.move(9, to: P(1, 1)), TouchChange(output: false, visual: false, haptic: false))
    }

    func testABeginOnATouchAlreadyOwnedReplacesIt() {
        var p = pad()
        _ = p.begin(1, at: P(44, 40))
        _ = p.begin(1, at: P(888, 40))
        XCTAssertEqual(p.pressed, [.zr])
    }

    // MARK: blocked

    private func held(_ layout: TouchLayout = .flat) -> TouchPad {
        var p = pad(layout)
        _ = p.begin(1, at: P(44, 40)); _ = p.begin(2, at: P(901, 348)); _ = p.begin(3, at: P(81, 348)); _ = p.move(3, to: P(142.6, 348))
        XCTAssertNotEqual(p.output, .neutral)
        return p
    }

    func testEachReasonThatBlocksReleasesEveryFinger() {
        for (name, reason) in [("menu", TouchBlockers.menu), ("background", .background), ("covered", .covered), ("controller", .controller)] {
            var p = held()
            let c = p.setBlockers(reason)
            XCTAssertEqual(p.output, .neutral, name); XCTAssertTrue(c.output, name); XCTAssertEqual(p.knob, P(0, 0), name)
            XCTAssertEqual(p.blockers, reason, name)
            // the old fingers are nobody's: their moves and ends change nothing
            XCTAssertEqual(p.move(3, to: P(100, 300)), TouchChange(), name)
            XCTAssertEqual(p.end(1), TouchChange(), name)
        }
    }

    func testNoFingerIsTakenWhileAnythingBlocks() {
        for reason in [TouchBlockers.menu, .background, .covered, .controller] {
            var p = pad()
            _ = p.setBlockers(reason)
            XCTAssertEqual(p.begin(1, at: P(44, 40)), TouchChange())
            XCTAssertEqual(p.pressed, [])
            _ = p.setBlockers([])
            XCTAssertTrue(p.begin(1, at: P(44, 40)).output, "a finger is taken again once nothing blocks")
            XCTAssertEqual(p.pressed, [.zl])
        }
    }

    func testAReasonAddedToAnotherStillReleasesAndOneLeftKeepsBlocking() {
        var p = pad()
        _ = p.setBlockers(.menu)
        _ = p.setBlockers([.menu, .covered])
        _ = p.setBlockers(.covered)  // the menu closed under a cover
        XCTAssertEqual(p.begin(1, at: P(44, 40)), TouchChange())
        XCTAssertEqual(p.setBlockers(.covered), TouchChange(), "the same reasons change nothing")
    }

    func testTheGearStaysWhileTheControllerBlocks() {
        var p = pad()
        _ = p.setBlockers(.controller)
        XCTAssertTrue(p.gearTakes(P(466, 22), controlsShown: false))
    }

    // MARK: the numbers panel

    private func intersects(_ a: TouchRect, _ b: TouchRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// The sizes the tests use: an iPhone with the notch's side insets, a small one, an iPad, an iPad mini.
    private var screens: [(String, TouchGeometry)] {
        [("phone", TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 932, height: 430), insets: TouchInsets(top: 0, left: 59, bottom: 21, right: 59))),
         ("small phone", TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 852, height: 393), insets: TouchInsets(top: 0, left: 59, bottom: 21, right: 59))),
         ("tablet", TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 1194, height: 834), insets: TouchInsets(top: 24, left: 0, bottom: 20, right: 0))),
         ("tablet mini", TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 1133, height: 744), insets: TouchInsets(top: 24, left: 0, bottom: 20, right: 0))),
         ("plain", TouchGeometry(bounds: flat, insets: none))]
    }

    func testEveryControlHasAFrame() {
        for layout in [TouchLayout.flat, .full] {
            let p = pad(layout)
            let frames = p.controlFrames()
            XCTAssertEqual(frames.count, p.shapes().count + 2, "one per shape, the ring, the menu button's hit circle")
            for s in p.shapes() {
                XCTAssertTrue(frames.contains { $0.contains(s.centre) }, "\(String(describing: s.button)) lies in a frame")
            }
            let r = p.ring
            XCTAssertTrue(frames.contains(TouchRect(x: r.centre.x - r.radius, y: r.centre.y - r.radius, width: 2 * r.radius, height: 2 * r.radius)))
        }
    }

    /// The panel's sizes as the app draws them: the lines of each level (with a loaded Mac), sized by `estimatedSize`.
    private var panelSizes: [(String, Double, Double)] {
        var p = ClientModel.PlayStats()
        p.macFps = 60; p.width = 1920; p.height = 1080; p.bitrateMbps = 48.6
        p.load = HostLoad(gpuPresent: true, gameAlive: true, thermal: 1, pressure: 0, cpuTotal: 412, cpuPerf: 551, cpuEff: 120, gpu: 783,
                          memUsedMiB: 18_330, memTotalMiB: 32_768, gameCpuCentiCores: 160, gameMemMiB: 6_250, gameFpsDeci: 600,
                          frameMeanDeciMs: 167, frameP95DeciMs: 190, frameMaxDeciMs: 410)
        return [PanelLevel.fps, .compact, .full].map { level in
            let size = TouchPanel.estimatedSize(lines: PanelText.lines(level: level, stats: p, pacing: .smooth), full: level == .full)
            return ("\(level)", size.width, size.height)
        }
    }

    func testThePanelNeverCoversAControlNorTheGear() {
        for (name, g) in screens {
            for (level, w, h) in panelSizes {
                let gear = TouchPad(geometry: g, layout: .flat).gearFrame
                for shown in [true, false] {
                    let f = TouchPanel.frame(width: w, height: h, geometry: g, controlsShown: shown)
                    let where_ = "\(name) \(level) \(Int(w))x\(Int(h)) controls \(shown ? "shown" : "hidden"): \(f)"
                    XCTAssertFalse(intersects(f, gear), "the gear: \(where_)")
                    let s = g.safe
                    XCTAssertGreaterThanOrEqual(f.minX, s.minX, where_); XCTAssertLessThanOrEqual(f.maxX, s.maxX, where_)
                    XCTAssertGreaterThanOrEqual(f.minY, s.minY, where_); XCTAssertLessThanOrEqual(f.maxY, s.maxY, where_)
                    XCTAssertEqual(f.width, w); XCTAssertEqual(f.height, h)
                    guard shown else { continue }
                    XCTAssertEqual(f.midX, s.midX, accuracy: 0.01, "top centre: \(where_)")
                    for layout in [TouchLayout.flat, .full] {
                        for c in TouchPad(geometry: g, layout: layout).controlFrames() {
                            XCTAssertFalse(intersects(f, c), "\(layout): \(where_) over \(c)")
                        }
                    }
                }
            }
        }
    }

    /// Hidden controls: top left, and moved down under the gear only where it would reach it.
    func testWithoutControlsThePanelStaysTopLeftUnlessItWouldTouchTheGear() {
        for (name, g) in screens {
            let gear = TouchPad(geometry: g, layout: .flat).gearFrame
            for (level, w, h) in panelSizes {
                let f = TouchPanel.frame(width: w, height: h, geometry: g, controlsShown: false)
                XCTAssertEqual(f.minX, g.safe.minX + 8, "\(name) \(level)")
                let topLeft = TouchRect(x: g.safe.minX + 8, y: g.safe.minY + 8, width: w, height: h)
                if intersects(topLeft, gear) { XCTAssertGreaterThanOrEqual(f.minY, gear.maxY, "under the gear: \(name) \(level)") }
                else { XCTAssertEqual(f.minY, g.safe.minY + 8, "\(name) \(level)") }
            }
        }
    }

    func testThePanelSitsUnderTheCentreRowAndStaysPutWithoutControls() {
        for (name, g) in screens {
            let p = TouchPad(geometry: g, layout: .flat)
            let f = TouchPanel.frame(width: 336, height: 28, geometry: g, controlsShown: true)
            let row = [p.gear.centre.y + p.gear.radius] + [PadButtons.minus, .plus].compactMap { b in p.shapes().first { $0.button == b }?.rect?.maxY }
            XCTAssertGreaterThan(f.minY, row.max() ?? 0, "below the pills and the gear: \(name)")
            let h = TouchPanel.frame(width: 336, height: 28, geometry: g, controlsShown: false)
            XCTAssertEqual(h.minX, g.safe.minX + 8, name); XCTAssertEqual(h.minY, g.safe.minY + 8, name)
        }
    }
}

final class TouchBlockerReasonsTests: XCTestCase {
    func testEachFactMapsToItsOwnReasonAndNothingElse() {
        XCTAssertEqual(TouchBlockers.reasons(menu: false, sceneActive: true, coverShown: false, controllerPresent: false), [])
        XCTAssertEqual(TouchBlockers.reasons(menu: true, sceneActive: true, coverShown: false, controllerPresent: false), .menu)
        XCTAssertEqual(TouchBlockers.reasons(menu: false, sceneActive: false, coverShown: false, controllerPresent: false), .background)
        XCTAssertEqual(TouchBlockers.reasons(menu: false, sceneActive: true, coverShown: true, controllerPresent: false), .covered)
        XCTAssertEqual(TouchBlockers.reasons(menu: false, sceneActive: true, coverShown: false, controllerPresent: true), .controller)
        XCTAssertEqual(TouchBlockers.reasons(menu: true, sceneActive: false, coverShown: true, controllerPresent: true),
                       [.menu, .background, .covered, .controller])
    }
}
