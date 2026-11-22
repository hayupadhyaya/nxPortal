import PortalKit
import PortalClientCore

/// A game controller's state under GameController's own names and values.
public struct PadSnapshot: Equatable, Sendable {
    /// The printed A/B/X/Y sit where the game console's do, so buttons map by label, not by position
    /// (Apple's productCategory values, set in `ControllerInput`).
    public var usesPrintedLabels = false
    public var buttonA = false, buttonB = false, buttonX = false, buttonY = false
    public var leftShoulder = false, rightShoulder = false
    public var leftTrigger: Float = 0, rightTrigger: Float = 0
    public var menu = false, options = false, leftStick = false, rightStick = false
    /// The controller's Home button, when it has one: the menu's, never the game's (`ControllerInput.onMenuToggle`).
    public var home = false
    public var left = false, up = false, right = false, down = false
    public var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0
    public init() {}

    /// The buttons held now, one bit each (the triggers past 0.25, as in `PadMapping.buttons`); sticks' axes are not buttons.
    var heldButtons: UInt32 {
        let flags = [buttonA, buttonB, buttonX, buttonY, leftShoulder, rightShoulder, menu, options, leftStick, rightStick,
                     left, up, right, down, leftTrigger > 0.25, rightTrigger > 0.25]
        var m: UInt32 = 0
        for (i, held) in flags.enumerated() where held { m |= 1 << UInt32(i) }
        return m
    }

    /// This state with the buttons in `mask` (bits as in `heldButtons`) released, and Home never in it (it is not the game's).
    func releasing(_ mask: UInt32) -> PadSnapshot {
        func off(_ bit: UInt32, _ held: Bool) -> Bool { mask & (1 << bit) != 0 ? false : held }
        var s = self
        s.buttonA = off(0, buttonA); s.buttonB = off(1, buttonB); s.buttonX = off(2, buttonX); s.buttonY = off(3, buttonY)
        s.leftShoulder = off(4, leftShoulder); s.rightShoulder = off(5, rightShoulder)
        s.menu = off(6, menu); s.options = off(7, options); s.leftStick = off(8, leftStick); s.rightStick = off(9, rightStick)
        s.left = off(10, left); s.up = off(11, up); s.right = off(12, right); s.down = off(13, down)
        if mask & (1 << 14) != 0 { s.leftTrigger = 0 }
        if mask & (1 << 15) != 0 { s.rightTrigger = 0 }
        s.home = false
        return s
    }
}

/// Equal to nxnative's pad_apple.h and front_mac.m pad_read -> .claude/client.md § input
public enum PadMapping {
    public static func buttons(_ s: PadSnapshot, layout: ClientSettings.PadLayout) -> PadButtons {
        let byName: Bool
        switch layout {
        case .auto: byName = s.usesPrintedLabels
        case .byLabel: byName = true
        case .byPosition: byName = false
        }
        var m: PadButtons = []
        // By position: GameController's bottom button is the runtime's B, right A, left Y, top X.
        if byName {
            if s.buttonA { m.insert(.a) }; if s.buttonB { m.insert(.b) }
            if s.buttonX { m.insert(.x) }; if s.buttonY { m.insert(.y) }
        } else {
            if s.buttonB { m.insert(.a) }; if s.buttonA { m.insert(.b) }
            if s.buttonY { m.insert(.x) }; if s.buttonX { m.insert(.y) }
        }
        if s.leftShoulder { m.insert(.l) }; if s.rightShoulder { m.insert(.r) }
        if s.leftTrigger > 0.25 { m.insert(.zl) }; if s.rightTrigger > 0.25 { m.insert(.zr) }
        if s.menu { m.insert(.plus) }; if s.options { m.insert(.minus) }
        if s.leftStick { m.insert(.stickL) }; if s.rightStick { m.insert(.stickR) }
        if s.left { m.insert(.left) }; if s.up { m.insert(.up) }
        if s.right { m.insert(.right) }; if s.down { m.insert(.down) }
        return m
    }

    /// NaN is 0; clamped to -1...1, times 32767, truncated toward zero.
    public static func axis(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(max(-1, min(1, v)) * 32767)
    }
}

/// Combines the newest pad and motion readings into what is sent. No clock, no framework types.
public struct InputMixer: Sendable {
    private let layout: ClientSettings.PadLayout
    private let mode: ClientSettings.DeviceMotion
    private var padState: PadSnapshot?
    private var controller: MotionSample?
    private var controllerAtNs: UInt64 = 0
    private var device: MotionSample?
    private var touchState: TouchOutput?

    /// In `auto` the controller's sensor counts while its newest sample is younger than this.
    public static let controllerFreshNs: UInt64 = 500_000_000

    public init(settings: ClientSettings) {
        layout = settings.padLayout
        mode = settings.deviceMotion
    }

    /// nil: the controller is gone (its motion goes with it).
    public mutating func pad(_ s: PadSnapshot?) {
        padState = s
        if s == nil { controller = nil }
    }
    /// The on-screen controller's state; nil when it is not in use. A game controller, while one is in use, takes its place.
    public mutating func touch(_ t: TouchOutput?) { touchState = t }
    public mutating func controllerMotion(_ m: MotionSample?, atNs: UInt64 = uptimeNs()) { controller = m; controllerAtNs = atNs }
    public mutating func deviceMotion(_ m: MotionSample?, atNs: UInt64 = uptimeNs()) { device = m }

    /// Player 0, seq 0 (the session numbers it).
    public var current: InputState { current(atNs: uptimeNs()) }

    public func current(atNs now: UInt64) -> InputState {
        let motion: MotionSample?
        switch mode {
        case .never: motion = controller
        case .always: motion = device
        case .auto: motion = controller.flatMap { now &- controllerAtNs < Self.controllerFreshNs ? $0 : nil } ?? device
        }
        guard let s = padState else {
            let t = touchState ?? .neutral
            return InputState(seq: 0, player: 0, buttons: t.buttons.rawValue, lx: t.lx, ly: t.ly, rx: t.rx, ry: t.ry, motion: motion)
        }
        return InputState(seq: 0, player: 0, buttons: PadMapping.buttons(s, layout: layout).rawValue,
                          lx: PadMapping.axis(s.lx), ly: PadMapping.axis(s.ly),
                          rx: PadMapping.axis(s.rx), ry: PadMapping.axis(s.ry), motion: motion)
    }
}
