import XCTest
import PortalKit
@testable import PortalPlayer

final class InputMixerTests: XCTestCase {
    private let c = MotionMapping.controller(acceleration: [1, 0, 0], rotation: [0, 1, 0])
    private let d = MotionMapping.device(orientation: 1, acceleration: [0, 0, 1], rotation: [1, 0, 0])

    private func mixer(_ mode: ClientSettings.DeviceMotion, layout: ClientSettings.PadLayout = .auto) -> InputMixer {
        var s = ClientSettings(); s.deviceMotion = mode; s.padLayout = layout
        return InputMixer(settings: s)
    }

    func testMixerMotionModes() {
        var never = mixer(.never)
        XCTAssertNil(never.current.motion)
        never.controllerMotion(c); never.deviceMotion(d)
        XCTAssertEqual(never.current.motion, c)
        never.controllerMotion(nil)
        XCTAssertNil(never.current.motion)

        var always = mixer(.always)
        always.controllerMotion(c)
        XCTAssertNil(always.current.motion)
        always.deviceMotion(d)
        XCTAssertEqual(always.current.motion, d)

        var auto = mixer(.auto)
        XCTAssertNil(auto.current.motion)
        auto.deviceMotion(d)
        XCTAssertEqual(auto.current.motion, d)
        auto.controllerMotion(c)
        XCTAssertEqual(auto.current.motion, c)
        auto.controllerMotion(nil)
        XCTAssertEqual(auto.current.motion, d)
    }

    func testAutoMotionFallsBackToDevice() {
        var m = mixer(.auto)
        let t0: UInt64 = 10_000_000_000
        m.deviceMotion(d, atNs: t0)
        m.controllerMotion(c, atNs: t0)
        XCTAssertEqual(m.current(atNs: t0 + 400_000_000).motion, c, "a sample younger than 500 ms is the controller's")
        m.deviceMotion(d, atNs: t0 + 600_000_000)
        XCTAssertEqual(m.current(atNs: t0 + 600_000_000).motion, d, "the controller went silent")
        m.controllerMotion(c, atNs: t0 + 700_000_000)
        XCTAssertEqual(m.current(atNs: t0 + 710_000_000).motion, c, "it resumed")
        var never = mixer(.never)
        never.controllerMotion(c, atNs: t0)
        XCTAssertEqual(never.current(atNs: t0 + 5_000_000_000).motion, c, "only auto falls back")
    }

    func testMixerControllerGoneIsNeutral() {
        var m = mixer(.never)
        var s = PadSnapshot()
        s.buttonA = true; s.leftShoulder = true; s.lx = 1; s.ly = -1; s.rx = 0.5; s.ry = -0.5
        m.pad(s)
        m.controllerMotion(c)
        let on = m.current
        XCTAssertEqual(on.buttons, (PadButtons.b.union(.l)).rawValue)
        XCTAssertEqual([on.lx, on.ly, on.rx, on.ry], [32767, -32767, 16383, -16383])
        XCTAssertEqual(on.player, 0)
        XCTAssertEqual(on.seq, 0)
        m.pad(nil)
        let off = m.current
        XCTAssertEqual(off.buttons, 0)
        XCTAssertEqual([off.lx, off.ly, off.rx, off.ry], [0, 0, 0, 0])
        XCTAssertNil(off.motion)
        m.controllerMotion(nil)
        XCTAssertNil(m.current.motion)
    }

    func testMixerUsesLayoutSetting() {
        var m = mixer(.auto, layout: .byLabel)
        var s = PadSnapshot(); s.buttonA = true
        m.pad(s)
        XCTAssertEqual(m.current.buttons, PadButtons.a.rawValue)
    }

    func testTouchFeedsTheMixerUntilAPadTakesOver() {
        var m = mixer(.auto)
        var t = TouchOutput.neutral
        t.buttons = [.a]; t.lx = 1000
        m.touch(t)
        XCTAssertEqual(m.current.buttons, PadButtons.a.rawValue); XCTAssertEqual(m.current.lx, 1000)
        var pad = PadSnapshot(); pad.buttonB = true
        m.pad(pad)
        XCTAssertEqual(m.current.buttons, PadButtons.a.rawValue, "B by position is the console's A")
        XCTAssertEqual(m.current.lx, 0, "the pad's sticks, not the touch's")
        pad.buttonB = false; pad.buttonX = true
        m.pad(pad)
        XCTAssertEqual(m.current.buttons, PadButtons.y.rawValue)
        m.pad(nil)
        XCTAssertEqual(m.current.buttons, PadButtons.a.rawValue); XCTAssertEqual(m.current.lx, 1000)
        m.touch(nil)
        XCTAssertEqual(m.current.buttons, 0); XCTAssertEqual(m.current.lx, 0)
    }

    func testTouchKeepsTheMotion() {
        var m = mixer(.always)
        m.deviceMotion(d)
        var t = TouchOutput.neutral; t.ry = -5; t.buttons = .zr
        m.touch(t)
        XCTAssertEqual(m.current.motion, d); XCTAssertEqual(m.current.ry, -5); XCTAssertEqual(m.current.buttons, PadButtons.zr.rawValue)
    }
}
