// The on-screen controller's layout and touch rules: a port of the runtime's DmGamepad.m (the 2D and 3D layouts).
//
// MIT License
//
// Copyright (c) 2026 seedds
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import PortalKit

/// A point in the controller view's own space (points, y down). No UIKit here -> .claude/client.md § input
public struct TouchPoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct TouchRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    /// Half-open, as a rectangle on a screen: the right and bottom edges are outside.
    func contains(_ p: TouchPoint) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }
    func grown(by d: Double) -> TouchRect { TouchRect(x: x - d, y: y - d, width: width + 2 * d, height: height + 2 * d) }
}

public struct TouchInsets: Equatable, Sendable {
    public var top, left, bottom, right: Double
    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

/// The view's size and safe-area insets; `u` is the unit every length is a multiple of (1 = a 430-point-tall screen).
public struct TouchGeometry: Equatable, Sendable {
    public var bounds: TouchRect
    public var insets: TouchInsets
    public init(bounds: TouchRect, insets: TouchInsets) { self.bounds = bounds; self.insets = insets }

    public var u: Double { min(bounds.height / 430, 1.3) }
    /// Inside the safe area: shoulders, keys of the top row, the menu button.
    var safe: TouchRect {
        TouchRect(x: bounds.x + insets.left, y: bounds.y + insets.top,
                  width: bounds.width - insets.left - insets.right, height: bounds.height - insets.top - insets.bottom)
    }
    /// The bottom corners reach halfway into the side insets (only the rounded screen corner is there in landscape).
    var corner: TouchRect {
        let l = insets.left * 0.5, r = insets.right * 0.5
        return TouchRect(x: bounds.x + l, y: bounds.y + insets.top,
                         width: bounds.width - l - r, height: bounds.height - insets.top - insets.bottom)
    }
}

public enum TouchLayout: String, Codable, CaseIterable, Sendable { case flat = "2d", full = "3d" }

/// What the touch controller asks the game for; up is positive on every axis.
public struct TouchOutput: Equatable, Sendable {
    public var buttons: PadButtons
    public var lx, ly, rx, ry: Int32
    public init(buttons: PadButtons = [], lx: Int32 = 0, ly: Int32 = 0, rx: Int32 = 0, ry: Int32 = 0) {
        self.buttons = buttons; self.lx = lx; self.ly = ly; self.rx = rx; self.ry = ry
    }
    public static let neutral = TouchOutput()
}

/// What one call changed: the game's input, what is drawn, a light haptic tap.
public struct TouchChange: Equatable, Sendable {
    public var output: Bool, visual: Bool, haptic: Bool
    public init(output: Bool = false, visual: Bool = false, haptic: Bool = false) {
        self.output = output; self.visual = visual; self.haptic = haptic
    }
}

/// One control to draw; the view only paints these.
public struct TouchShape: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case circle, drop(tipAngle: Double), pill, arm(angle: Double) }
    public var button: PadButtons?
    public var kind: Kind
    public var centre: TouchPoint
    /// Circle and drop: the radius; pill: half its height; arm: the pad's outer edge from its centre.
    public var radius: Double
    public var rect: TouchRect?
    public var label: String?
    public var labelSize: Double
    /// Corner or tip rounding (drops, arms).
    public var rounding: Double = 0
    /// Arms: half-width and the tip's distance from the centre.
    public var armHalfWidth: Double = 0, armTip: Double = 0
}

/// Why the on-screen controls take no finger and hold nothing right now; each reason releases when it begins.
public struct TouchBlockers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The in-play menu is open.
    public static let menu = TouchBlockers(rawValue: 1)
    /// The app is not in the foreground.
    public static let background = TouchBlockers(rawValue: 2)
    /// A trouble screen covers the game.
    public static let covered = TouchBlockers(rawValue: 4)
    /// A game controller is in use (the controls are hidden).
    public static let controller = TouchBlockers(rawValue: 8)

    /// The reasons that follow from what the view knows: it passes facts and decides nothing.
    public static func reasons(menu: Bool, sceneActive: Bool, coverShown: Bool, controllerPresent: Bool) -> TouchBlockers {
        var b: TouchBlockers = []
        if menu { b.insert(.menu) }
        if !sceneActive { b.insert(.background) }
        if coverShown { b.insert(.covered) }
        if controllerPresent { b.insert(.controller) }
        return b
    }
}

public struct TouchPad: Sendable {
    public private(set) var geometry: TouchGeometry
    public private(set) var layout: TouchLayout
    public private(set) var output = TouchOutput.neutral
    public private(set) var pressed: PadButtons = []
    /// The left stick's knob from its ring's centre (y down), clamped to the ring.
    public private(set) var knob = TouchPoint(0, 0)

    private enum Owner: Equatable { case key(UInt64), face, dpad, stick(Int) }
    private var owners: [Int: Owner] = [:]
    private var positions: [Int: TouchPoint] = [:]
    private var faceOf: [Int: PadButtons] = [:]
    private var stickTouch: [Int?] = [nil, nil]
    private var stickNow = [TouchPoint(0, 0), TouchPoint(0, 0)]
    private var cameraCentre = TouchPoint(0, 0)
    private var gripped: Set<Int> = []
    public private(set) var blockers: TouchBlockers = []

    // Lengths in u; x from the outer edge, the right half mirrors (the runtime's K_* constants).
    private enum K {
        static let zlX = 44.0, zlY = 40.0, zlR = 26.0, lX = 44.0, lY = 108.0, lR = 24.0
        static let dropTip = 1.45, dropRound = 4.0
        static let faceX = 81.0, padY = 82.0, faceGap = 50.0, faceR = 27.0
        static let pillDX = 52.0, pillY = 22.0, pillW = 50.0, pillH = 28.0, pillGrow = 8.0
        static let menuR = 15.0
        static let stickR = 77.0, knobR = 30.0, stickGrab = 1.4, full = 0.8, dead = 0.1
        static let lowX = 231.0, lowY = 64.0, dpadR = 48.0, armW = 17.0, armIn = 11.0, armRound = 6.0, dpadGrab = 1.3
        static let cameraR = 60.0, cameraArea = 1.0 / 3
        static let clickX = 102.0, clickR = 17.0
        static let lockedGrab = 1.35
    }

    public init(geometry: TouchGeometry, layout: TouchLayout) {
        self.geometry = geometry
        self.layout = layout
    }

    // MARK: geometry

    private var u: Double { geometry.u }
    private var isFull: Bool { layout == .full }

    private func side(_ r: TouchRect, right: Bool, _ dx: Double, _ y: Double) -> TouchPoint {
        TouchPoint(right ? r.maxX - dx : r.minX + dx, y)
    }

    private var faceCentre: TouchPoint {
        let c = geometry.corner
        return side(c, right: true, K.faceX * u, c.maxY - K.padY * u)
    }
    private var faceGap: Double { K.faceGap * u }
    private var faceR: Double { K.faceR * u }
    private var faceHitR: Double { max(faceR * 1.25, 0) }
    private func facePos(_ b: PadButtons) -> TouchPoint {
        let c = faceCentre, g = faceGap
        switch b {
        case .a: return TouchPoint(c.x + g, c.y)
        case .b: return TouchPoint(c.x, c.y + g)
        case .x: return TouchPoint(c.x, c.y - g)
        default: return TouchPoint(c.x - g, c.y)
        }
    }
    private var stickHome: TouchPoint {
        let c = geometry.corner
        return side(c, right: false, K.faceX * u, c.maxY - K.padY * u)
    }
    private var dpadCentre: TouchPoint {
        let c = geometry.corner
        return side(c, right: false, K.lowX * u, c.maxY - K.lowY * u)
    }
    private var dpadR: Double { K.dpadR * u }
    private func stickRadius(_ i: Int) -> Double { (i == 1 ? K.cameraR : K.stickR) * u }
    private func stickCentre(_ i: Int) -> TouchPoint { i == 1 ? cameraCentre : stickHome }
    private func inCameraArea(_ p: TouchPoint) -> Bool {
        let b = geometry.bounds
        return p.x >= b.maxX - b.width * K.cameraArea
    }

    private static let drops: [PadButtons] = [.zl, .l, .zr, .r]
    private static let pills: [PadButtons] = [.minus, .plus]
    private static let clicks: [PadButtons] = [.stickL, .stickR]
    /// Keys locked at touch-down, in the runtime's order (the clicks only in 3D).
    private var lockedKeys: [PadButtons] { [.zl, .l, .zr, .r, .minus, .plus] + (isFull ? Self.clicks : []) }

    private func dropCentre(_ b: PadButtons) -> TouchPoint {
        let s = geometry.safe, z = b == .zl || b == .zr
        return side(s, right: b == .zr || b == .r, (z ? K.zlX : K.lX) * u, s.minY + (z ? K.zlY : K.lY) * u)
    }
    private func dropRadius(_ b: PadButtons) -> Double { (b == .zl || b == .zr ? K.zlR : K.lR) * u }
    private func clickCentre(_ b: PadButtons) -> TouchPoint {
        let s = geometry.safe
        return side(s, right: b == .stickR, K.clickX * u, s.minY + K.zlY * u)
    }
    private func pillRect(_ b: PadButtons) -> TouchRect {
        let s = geometry.safe, w = K.pillW * u, h = K.pillH * u
        let cx = s.midX + (b == .plus ? K.pillDX : -K.pillDX) * u, cy = s.minY + K.pillY * u
        return TouchRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
    private var gearCentre: TouchPoint { TouchPoint(geometry.safe.midX, geometry.safe.minY + K.pillY * u) }

    /// A finger holds the left stick (its knob is drawn lit).
    public var leftStickHeld: Bool { stickTouch[0] != nil }

    /// Every control's bounding frame (a drop includes its tip), the left stick's ring and the menu button's whole hit circle.
    public func controlFrames() -> [TouchRect] {
        func box(_ c: TouchPoint, _ r: Double) -> TouchRect { TouchRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
        var out: [TouchRect] = shapes().map { s in
            switch s.kind {
            case .pill: s.rect ?? box(s.centre, s.radius)
            case .drop: box(s.centre, s.radius * K.dropTip)
            case .circle, .arm: box(s.centre, s.radius)
            }
        }
        out.append(box(stickHome, K.stickR * u))
        out.append(box(gearCentre, gearHitRadius))
        return out
    }

    /// Below this line the menu button's hit circle and both pills (with their grown hit areas) are over.
    var menuRowBottom: Double {
        let pill = pillRect(.minus).grown(by: K.pillGrow * u)
        return max(gearCentre.y + gearHitRadius, pill.maxY)
    }
    /// The menu button's whole hit circle as a frame: the numbers panel never covers it.
    public var gearFrame: TouchRect { let r = gearHitRadius; return TouchRect(x: gearCentre.x - r, y: gearCentre.y - r, width: 2 * r, height: 2 * r) }
    private var gearHitRadius: Double { max(K.menuR * u * 1.6, 22) }

    public var gear: (centre: TouchPoint, radius: Double) { (gearCentre, K.menuR * u) }
    public var ring: (centre: TouchPoint, radius: Double, knobRadius: Double) { (stickHome, K.stickR * u, K.knobR * u) }

    private func dist(_ a: TouchPoint, _ b: TouchPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// Distance over reach for a locked key: 1 or less is a hit; infinity when out of reach.
    private func keyDistance(_ b: PadButtons, _ p: TouchPoint) -> Double {
        if Self.drops.contains(b) { return dist(p, dropCentre(b)) / (dropRadius(b) * K.lockedGrab) }
        if Self.clicks.contains(b) { return dist(p, clickCentre(b)) / (K.clickR * u * K.lockedGrab) }
        let r = pillRect(b).grown(by: K.pillGrow * u)
        guard r.contains(p) else { return .infinity }
        return max(abs(p.x - r.midX) / (r.width / 2), abs(p.y - r.midY) / (r.height / 2))
    }
    private func keyAt(_ p: TouchPoint) -> PadButtons? {
        lockedKeys.first { keyDistance($0, p) <= 1 }
    }

    /// The menu button takes a touch in its circle unless a locked key is nearer; it is a view of its own, so the view asks.
    /// With the controls hidden (a game controller is in use) no key competes for the touch.
    public func gearTakes(_ p: TouchPoint, controlsShown: Bool = true) -> Bool {
        let d = dist(p, gearCentre) / gearHitRadius
        if d > 1 { return false }
        if !controlsShown { return true }
        guard let hit = keyAt(p) else { return true }
        return d < keyDistance(hit, p)
    }

    private func faceKeys(at p: TouchPoint) -> PadButtons {
        var m: PadButtons = []
        for b in [PadButtons.a, .b, .x, .y] where dist(p, facePos(b)) <= faceHitR { m.insert(b) }
        return m
    }

    /// Eight directions of 45 degrees, diagonals press two; a small circle at the centre is none.
    private func dpadKeys(at p: TouchPoint) -> PadButtons {
        let c = dpadCentre, dx = p.x - c.x, dy = p.y - c.y
        if hypot(dx, dy) < dpadR * 0.25 { return [] }
        let a = atan2(-dy, dx) * 180 / .pi
        var m: PadButtons = []
        if a > -67.5 && a < 67.5 { m.insert(.right) }
        if a > 22.5 && a < 157.5 { m.insert(.up) }
        if a > 112.5 || a < -112.5 { m.insert(.left) }
        if a < -22.5 && a > -157.5 { m.insert(.down) }
        return m
    }

    private func knobOffset(_ i: Int) -> TouchPoint {
        guard stickTouch[i] != nil else { return TouchPoint(0, 0) }
        let h = stickCentre(i), r = stickRadius(i)
        var dx = stickNow[i].x - h.x, dy = stickNow[i].y - h.y
        let d = hypot(dx, dy)
        if d > r { dx = dx * r / d; dy = dy * r / d }
        return TouchPoint(dx, dy)
    }

    // MARK: shapes

    public func shapes() -> [TouchShape] {
        var out: [TouchShape] = []
        func name(_ b: PadButtons) -> String? {
            switch b {
            case .a: "A"
            case .b: "B"
            case .x: "X"
            case .y: "Y"
            case .stickL: "L3"
            case .stickR: "R3"
            case .l: "L"
            case .r: "R"
            case .zl: "ZL"
            case .zr: "ZR"
            case .plus: "+"
            case .minus: "\u{2212}"
            default: nil
            }
        }
        for b in [PadButtons.a, .b, .x, .y] {
            out.append(TouchShape(button: b, kind: .circle, centre: facePos(b), radius: faceR, rect: nil, label: name(b), labelSize: 20 * u))
        }
        for b in lockedKeys {
            if Self.drops.contains(b) {
                let right = b == .zr || b == .r
                var s = TouchShape(button: b, kind: .drop(tipAngle: right ? -Double.pi / 4 : -3 * Double.pi / 4), centre: dropCentre(b),
                                   radius: dropRadius(b), rect: nil, label: name(b), labelSize: 16 * u)
                s.rounding = K.dropRound * u
                out.append(s)
            } else if Self.clicks.contains(b) {
                out.append(TouchShape(button: b, kind: .circle, centre: clickCentre(b), radius: K.clickR * u, rect: nil, label: name(b), labelSize: 13 * u))
            } else {
                let r = pillRect(b)
                out.append(TouchShape(button: b, kind: .pill, centre: TouchPoint(r.midX, r.midY), radius: r.height / 2, rect: r, label: name(b), labelSize: 18 * u))
            }
        }
        if isFull {
            for (b, angle) in [(PadButtons.up, 0.0), (.right, Double.pi / 2), (.down, Double.pi), (.left, -Double.pi / 2)] {
                var s = TouchShape(button: b, kind: .arm(angle: angle), centre: dpadCentre, radius: dpadR, rect: nil, label: nil, labelSize: 0)
                s.rounding = K.armRound * u; s.armHalfWidth = K.armW * u; s.armTip = K.armIn * u
                out.append(s)
            }
        }
        return out
    }

    // MARK: touches

    private static let nothing = TouchChange()

    public mutating func begin(_ id: Int, at p: TouchPoint) -> TouchChange {
        let before = snapshot
        forget(id)
        if blockers.isEmpty, !gearTakes(p) { claim(id, at: p) }
        return changed(since: before)
    }

    private mutating func claim(_ id: Int, at p: TouchPoint) {
        if let key = keyAt(p) { owners[id] = .key(key.rawValue); positions[id] = p; return }
        // The diamond, the D-pad and the left stick: the smallest distance over grab radius, at most 1.
        var best = 1.0, kind: Owner?
        let f = dist(p, faceCentre) / (faceGap + max(faceR * 1.6, faceHitR))
        if f <= best { best = f; kind = .face }
        if isFull {
            let d = dist(p, dpadCentre) / max(dpadR * K.dpadGrab, 0)
            if d < best { best = d; kind = .dpad }
        }
        if stickTouch[0] == nil {
            let s = dist(p, stickHome) / (K.stickR * u * K.stickGrab)
            if s < best { best = s; kind = .stick(0) }
        }
        if kind == nil, isFull, stickTouch[1] == nil, inCameraArea(p) { kind = .stick(1); cameraCentre = p }
        guard let kind else { return }
        owners[id] = kind
        positions[id] = p
        switch kind {
        case .face: faceOf[id] = faceKeys(at: p)
        case .stick(let i): stickTouch[i] = id; stickNow[i] = p
        default: break
        }
    }

    public mutating func move(_ id: Int, to p: TouchPoint) -> TouchChange {
        guard let owner = owners[id] else { return Self.nothing }
        let before = snapshot
        positions[id] = p
        switch owner {
        case .face: faceOf[id] = faceKeys(at: p)
        case .stick(let i):
            stickNow[i] = p
            if i == 1 {  // the camera's centre follows a finger past its radius, so turning back responds at once
                let d = dist(p, cameraCentre), r = stickRadius(1)
                if d > r { cameraCentre = TouchPoint(p.x - (p.x - cameraCentre.x) * r / d, p.y - (p.y - cameraCentre.y) * r / d) }
            }
        default: break
        }
        return changed(since: before)
    }

    /// A finger lifted or its touch cancelled.
    public mutating func end(_ id: Int) -> TouchChange {
        guard owners[id] != nil else { return Self.nothing }
        let before = snapshot
        forget(id)
        return changed(since: before)
    }

    /// Which reasons block the controls now; a reason that begins releases every finger, and while any holds no finger is taken.
    public mutating func setBlockers(_ b: TouchBlockers) -> TouchChange {
        let began = !blockers.isSuperset(of: b)
        blockers = b
        return began ? releaseAll() : Self.nothing
    }

    public mutating func releaseAll() -> TouchChange {
        let before = snapshot
        clear()
        return changed(since: before, forceVisual: false)
    }

    /// A new size or inset: equal changes nothing; another releases every finger (a finger held across it must not stay a key).
    public mutating func setGeometry(_ g: TouchGeometry) -> TouchChange {
        guard g != geometry else { return Self.nothing }
        let before = snapshot
        clear()
        geometry = g
        return changed(since: before, forceVisual: true)
    }

    public mutating func setLayout(_ l: TouchLayout) -> TouchChange {
        guard l != layout else { return Self.nothing }
        let before = snapshot
        clear()
        layout = l
        return changed(since: before, forceVisual: true)
    }

    private mutating func forget(_ id: Int) {
        owners[id] = nil; positions[id] = nil; faceOf[id] = nil
        for i in 0..<2 where stickTouch[i] == id { stickTouch[i] = nil }
    }

    private mutating func clear() {
        owners = [:]; positions = [:]; faceOf = [:]; stickTouch = [nil, nil]
    }

    // MARK: output

    private struct Snapshot: Equatable { var output: TouchOutput; var pressed: PadButtons; var knob: TouchPoint; var gripped: Set<Int> }
    private var snapshot: Snapshot { Snapshot(output: output, pressed: pressed, knob: knob, gripped: gripped) }

    /// Recomputes what is held and returns what differs from `before`.
    private mutating func changed(since before: Snapshot, forceVisual: Bool = false) -> TouchChange {
        var keys: PadButtons = []
        for (id, owner) in owners {
            switch owner {
            case .key(let raw): keys.formUnion(PadButtons(rawValue: raw))
            case .face: keys.formUnion(faceOf[id] ?? [])
            case .dpad: if let p = positions[id] { keys.formUnion(dpadKeys(at: p)) }
            case .stick: break
            }
        }
        var ax = [Int32](repeating: 0, count: 4)
        for i in 0..<2 {
            let o = knobOffset(i), r = stickRadius(i), d = hypot(o.x, o.y), dz = r * K.dead
            if d <= dz { continue }
            let m = min((d - dz) / (r * K.full - dz), 1) / d
            ax[i * 2] = Int32((o.x * m * 32767).rounded(.toNearestOrEven))
            ax[i * 2 + 1] = Int32((-o.y * m * 32767).rounded(.toNearestOrEven))  // up is positive
        }
        pressed = keys
        output = TouchOutput(buttons: keys, lx: ax[0], ly: ax[1], rx: ax[2], ry: ax[3])
        knob = knobOffset(0)
        gripped = Set((0..<2).filter { stickTouch[$0] != nil })
        let newKeys = !before.pressed.isSuperset(of: keys)
        let newGrip = !before.gripped.isSuperset(of: gripped)
        let visual = forceVisual || pressed != before.pressed || knob != before.knob || gripped != before.gripped
        return TouchChange(output: output != before.output, visual: visual, haptic: newKeys || newGrip)
    }
}
