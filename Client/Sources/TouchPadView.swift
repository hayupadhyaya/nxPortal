#if os(iOS)
// The on-screen controller's drawing and touch forwarding: a port of the runtime's DmGamepad.m (the 2D and 3D layouts).
// All geometry and hit rules live in `PortalPlayer.TouchPad`; this view paints its shapes and forwards fingers to it.
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

import PortalKit
import PortalPlayer
import SwiftUI
import UIKit

/// The menu button: its hit circle is larger than the drawn one, and a key nearer to the touch wins, so it asks the pad.
private final class GearButton: UIButton {
    var takes: ((CGPoint) -> Bool)?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { takes?(point) ?? super.point(inside: point, with: event) }
}

final class TouchPadView: UIView {
    /// The whole state, after every change (the model sends it as the game's input).
    var onOutput: ((TouchOutput) -> Void)?
    var onGear: (() -> Void)?
    var haptics = true

    private var pad = TouchPad(geometry: TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: 932, height: 430),
                                                       insets: TouchInsets(top: 0, left: 0, bottom: 0, right: 0)), layout: .flat)
    private struct Key { let button: PadButtons?; let layer = CAShapeLayer(); let label: CATextLayer? }
    private var keys: [Key] = []
    private let controls = CALayer()
    private let ring = CAShapeLayer(), knob = CAShapeLayer(), knobInner = CAShapeLayer()
    private let gear = GearButton(type: .custom)
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private lazy var directArea = UIAccessibilityElement(accessibilityContainer: self)
    private var lastGeometry: TouchGeometry?
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var controllerPresent = false
    private var palette: LookPalette { Theme.palette }

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        layer.addSublayer(controls)
        for l in [ring, knob] { style(l) }
        ring.fillColor = color(palette.touchRing)
        knobInner.fillColor = nil; knobInner.strokeColor = color(palette.touchOutline); knobInner.lineWidth = 1.5
        knob.addSublayer(knobInner)
        controls.addSublayer(ring); controls.addSublayer(knob)
        gear.backgroundColor = UIColor(cgColor: color(palette.touchIdle))
        gear.layer.borderColor = color(palette.touchOutline); gear.layer.borderWidth = 1.5
        gear.layer.shadowColor = color(palette.shadow); gear.layer.shadowOpacity = 0.2
        gear.layer.shadowRadius = 3; gear.layer.shadowOffset = CGSize(width: 0, height: 1)
        gear.tintColor = UIColor(cgColor: color(palette.touchLabel))
        gear.accessibilityLabel = TouchText.menuButton
        gear.takes = { [weak self] p in
            guard let self else { return false }
            let q = gear.convert(p, to: self)
            return pad.gearTakes(TouchPoint(q.x, q.y), controlsShown: !controllerPresent)
        }
        gear.addAction(UIAction { [weak self] _ in self?.releaseAll(); self?.onGear?() }, for: .touchUpInside)
        addSubview(gear)
        directArea.accessibilityLabel = TouchText.padName
        directArea.accessibilityTraits = .allowsDirectInteraction
        accessibilityElements = [gear, directArea]
        rebuildKeys()
        feedback.prepare()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: state from the app

    func setLayout(_ l: TouchLayout) {
        apply(pad.setLayout(l))
        rebuildKeys()
        setNeedsLayout()
    }

    /// Why the controls take no finger now (the menu, the background, a cover, a game controller in use): each that begins
    /// lets every finger go; a game controller also hides the controls (the gear stays).
    func setBlockers(_ b: TouchBlockers) {
        controllerPresent = b.contains(.controller)
        controls.isHidden = controllerPresent
        ids = [:]
        apply(pad.setBlockers(b))
    }

    /// Every finger lets go: the menu opens, the app goes to the background, a cover goes up.
    func releaseAll() {
        ids = [:]
        apply(pad.releaseAll())
    }

    /// Runs the gear's action as a tap would (the DEBUG launch flag; no tap automation exists).
    func performGear() { gear.sendActions(for: .touchUpInside) }

    // MARK: drawing

    private func color(_ c: RGBA) -> CGColor { UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a).cgColor }

    private func style(_ l: CAShapeLayer) {
        l.fillColor = color(palette.touchIdle); l.strokeColor = color(palette.touchOutline); l.lineWidth = 1.5
        l.shadowColor = color(palette.shadow); l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSize(width: 0, height: 1)
    }

    private func rebuildKeys() {
        for k in keys { k.layer.removeFromSuperlayer() }
        keys = pad.shapes().map { shape in
            let label: CATextLayer? = shape.label.map { text in
                let t = CATextLayer()
                t.string = text; t.alignmentMode = .center; t.foregroundColor = color(palette.touchLabel)
                return t
            }
            let k = Key(button: shape.button, label: label)
            style(k.layer)
            controls.addSublayer(k.layer)
            if let label { k.layer.addSublayer(label) }
            return k
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let i = safeAreaInsets
        let g = TouchGeometry(bounds: TouchRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
                              insets: TouchInsets(top: i.top, left: i.left, bottom: i.bottom, right: i.right))
        if g != lastGeometry { ids = [:]; lastGeometry = g }  // the pad released every finger: their later moves are nobody's
        apply(pad.setGeometry(g))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        controls.frame = layer.bounds
        let scale = max(traitCollection.displayScale, 1)
        for (key, shape) in zip(keys, pad.shapes()) {
            key.layer.path = path(for: shape); key.layer.shadowPath = key.layer.path
            if let label = key.label {
                if label.contentsScale != scale { label.contentsScale = scale; label.setNeedsDisplay() }
                let font = UIFont.systemFont(ofSize: shape.labelSize, weight: .bold)
                label.font = font; label.fontSize = shape.labelSize
                let h = font.ascender - font.descender + font.leading, w = shape.labelSize * 3
                label.frame = CGRect(x: shape.centre.x - w / 2, y: shape.centre.y - h / 2, width: w, height: h)
            }
        }
        let r = pad.ring
        ring.path = CGPath(ellipseIn: CGRect(x: r.centre.x - r.radius, y: r.centre.y - r.radius, width: 2 * r.radius, height: 2 * r.radius), transform: nil)
        let k = r.knobRadius
        knob.bounds = CGRect(x: 0, y: 0, width: 2 * k, height: 2 * k)
        knob.path = CGPath(ellipseIn: knob.bounds, transform: nil)
        knob.shadowPath = knob.path
        knobInner.frame = knob.bounds
        knobInner.path = CGPath(ellipseIn: CGRect(x: k * 0.38, y: k * 0.38, width: k * 1.24, height: k * 1.24), transform: nil)
        let gc = pad.gear
        gear.frame = CGRect(x: gc.centre.x - gc.radius, y: gc.centre.y - gc.radius, width: 2 * gc.radius, height: 2 * gc.radius)
        gear.layer.cornerRadius = gc.radius
        gear.layer.shadowPath = UIBezierPath(ovalIn: gear.bounds).cgPath
        gear.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13 * g.u, weight: .semibold)), for: .normal)
        CATransaction.commit()
        directArea.accessibilityFrameInContainerSpace = bounds
        refresh()
    }

    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }

    private func path(for s: TouchShape) -> CGPath {
        let c = CGPoint(x: s.centre.x, y: s.centre.y)
        switch s.kind {
        case .circle: return CGPath(ellipseIn: CGRect(x: c.x - s.radius, y: c.y - s.radius, width: 2 * s.radius, height: 2 * s.radius), transform: nil)
        case .pill:
            let r = s.rect ?? TouchRect(x: 0, y: 0, width: 0, height: 0)
            return CGPath(roundedRect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height), cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        case .drop(let tip): return dropPath(c, s.radius, tip, s.rounding)
        case .arm(let angle): return armPath(c, s.radius, s.armHalfWidth, s.armTip, angle, s.rounding)
        }
    }

    /// A teardrop: the circle and two tangents meeting at the tip, the tip slightly rounded.
    private func dropPath(_ c: CGPoint, _ r: CGFloat, _ tipAngle: CGFloat, _ round: CGFloat) -> CGPath {
        let d = r * 1.45, th = acos(r / d)
        let tip = CGPoint(x: c.x + d * cos(tipAngle), y: c.y + d * sin(tipAngle))
        let p1 = CGPoint(x: c.x + r * cos(tipAngle + th), y: c.y + r * sin(tipAngle + th))
        let p2 = CGPoint(x: c.x + r * cos(tipAngle - th), y: c.y + r * sin(tipAngle - th))
        let p = CGMutablePath()
        p.move(to: p2)
        p.addArc(tangent1End: tip, tangent2End: p1, radius: round)
        p.addArc(center: c, radius: r, startAngle: tipAngle + th, endAngle: tipAngle - th + 2 * .pi, clockwise: false)
        p.closeSubpath()
        return p
    }

    /// One D-pad arm: an upward pentagon (its tip toward the centre) turned by `angle` around the centre.
    private func armPath(_ c: CGPoint, _ outer: CGFloat, _ w: CGFloat, _ tipIn: CGFloat, _ angle: CGFloat, _ round: CGFloat) -> CGPath {
        let base: [CGPoint] = [CGPoint(x: -w, y: -outer), CGPoint(x: w, y: -outer), CGPoint(x: w, y: -(tipIn + w)),
                               CGPoint(x: 0, y: -tipIn), CGPoint(x: -w, y: -(tipIn + w))]
        let cs = cos(angle), sn = sin(angle)
        let v = base.map { CGPoint(x: c.x + $0.x * cs - $0.y * sn, y: c.y + $0.x * sn + $0.y * cs) }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (v[4].x + v[0].x) / 2, y: (v[4].y + v[0].y) / 2))
        for i in 0..<5 { p.addArc(tangent1End: v[i], tangent2End: v[(i + 1) % 5], radius: round) }
        p.closeSubpath()
        return p
    }

    /// A press swaps the fill, a stick moves its knob; nothing redraws the whole view.
    private func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for k in keys {
            let on = k.button.map { pad.pressed.contains($0) } ?? false
            k.layer.fillColor = color(on ? palette.touchPressed : palette.touchIdle)
            k.label?.foregroundColor = color(on ? palette.touchLabelPressed : palette.touchLabel)
        }
        let h = pad.ring.centre, o = pad.knob
        knob.position = CGPoint(x: h.x + o.x, y: h.y + o.y)
        knob.fillColor = color(pad.leftStickHeld ? palette.touchPressed : palette.touchIdle)
        CATransaction.commit()
    }

    private func apply(_ change: TouchChange) {
        if change.visual { refresh() }
        if change.output { onOutput?(pad.output) }
        if change.haptic, haptics { feedback.impactOccurred(intensity: 0.6); feedback.prepare() }
    }

    // MARK: touches

    /// With a game controller in use only the gear takes a touch.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        if controllerPresent { return v === gear ? v : nil }
        return v
    }

    private func point(_ t: UITouch) -> TouchPoint { let p = t.location(in: self); return TouchPoint(p.x, p.y) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            nextID += 1
            ids[ObjectIdentifier(t)] = nextID
            apply(pad.begin(nextID, at: point(t)))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { if let id = ids[ObjectIdentifier(t)] { apply(pad.move(id, to: point(t))) } }
    }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches { if let id = ids.removeValue(forKey: ObjectIdentifier(t)) { apply(pad.end(id)) } }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
}

/// The pad inside the play screen: the view is made once by the owner and kept.
struct TouchPadRepresentable: UIViewRepresentable {
    let view: TouchPadView
    func makeUIView(context: Context) -> TouchPadView { view }
    func updateUIView(_ uiView: TouchPadView, context: Context) {}
}
#endif
