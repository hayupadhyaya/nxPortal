import Foundation
import GameController
import os
import PortalKit
import PortalClientCore
#if os(iOS)
import CoreMotion
#endif

/// Reads GameController (and on iOS CoreMotion) into an `InputMixer` and sends its state on every change.
/// No mapping logic of its own -> .claude/client.md § input
///
/// Every framework handler is a non-isolated `@Sendable` closure that extracts plain values and calls a
/// `nonisolated` seam; the seam puts them in a lock-protected inbox and schedules one main-queue hop.
@MainActor public final class ControllerInput {
    public nonisolated var interfaceOrientation: Int {
        get { orientation.withLock { $0 } }
        set { orientation.withLock { $0 = newValue } }
    }
    public private(set) var controllerName: String?
    /// Called once per hold of Menu and Options together (`settings.menuChord`); the game still gets both buttons.
    public var onMenuChord: (@MainActor () -> Void)?
    /// B pressed (once per press) while `menuOpen`; B is then the menu's, never the game's.
    public var onBack: (@MainActor () -> Void)?
    /// The controller's Home button, when it has one, pressed (once per press): opens and closes the menu; never the game's.
    public var onMenuToggle: (@MainActor () -> Void)?
    /// A game controller became the one in use (true) or the last one went (false): the on-screen controls hide and show.
    public var presenceChanged: (@MainActor (Bool) -> Void)?
    private var present = false
    /// While true the game gets neutral input: one neutral input when it turns true, then nothing is sent; when it turns
    /// false the present state is sent, minus the buttons held at that moment until they are released (no stuck button).
    public var menuOpen = false {
        didSet { if menuOpen != oldValue { menuChanged() } }
    }
    /// The newest pad state as read (before the menu's rules), and what was last fed to the mixer.
    private var rawPad: PadSnapshot?
    private var lastShown: PadSnapshot?
    /// Buttons held when the menu closed, kept from the game until released.
    private var hiddenUntilReleased: UInt32 = 0
    private var homeHeld = false, backHeld = false
    /// The newest on-screen state as read (the menu's rules apply when it reaches the mixer).
    private var touchRaw = TouchOutput.neutral
    static let menuChordHoldNs: UInt64 = 500_000_000
    private var chordTask: Task<Void, Never>?
    private var chordFired = false

    /// Newest values not yet applied. Pad snapshots are full states and motion needs only the newest sample, so
    /// each slot is replaced, never queued: the main actor never has a backlog and nothing is applied out of order.
    private struct Inbox: Sendable {
        var accepting = false
        var scheduled = false
        var generation = 0
        var pad: (snapshot: PadSnapshot, from: ObjectIdentifier?)?
        var controllerMotion: (sample: MotionSample, from: ObjectIdentifier?)?
        var deviceMotion: MotionSample?
        var touch: TouchOutput?
    }

    private let settings: ClientSettings
    private let send: @Sendable (InputState) -> Void
    private let inbox = OSAllocatedUnfairLock(uncheckedState: Inbox())
    private let orientation = OSAllocatedUnfairLock(initialState: 1)
    private var mixer: InputMixer
    private var observers: [NSObjectProtocol] = []
    private var active: GCController?
    private var sensorsTurnedOn = false
    private var started = false
    #if os(iOS)
    private var motionManager: CMMotionManager?
    private let motionQueue = OperationQueue()
    #endif

    public init(settings: ClientSettings, send: @escaping @Sendable (InputState) -> Void) {
        self.settings = settings
        self.send = send
        self.mixer = InputMixer(settings: settings)
    }

    public func start() {
        guard !started else { return }
        started = true
        inbox.withLock { $0 = Inbox(accepting: true, generation: $0.generation + 1) }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controllersChanged() }
            },
            nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
                let gone = (n.object as? GCController).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.disconnected(gone) }
            },
            nc.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controllersChanged() }
            },
        ]
        adoptBest(excluding: nil)
        startDeviceMotion()
    }

    /// Must be called: there is no cleanup in `deinit`.
    public func stop() {
        guard started else { return }
        send(Self.neutralInput)  // nothing stays held on the Mac; sent directly, never through the inbox this call discards
        started = false
        inbox.withLock { $0 = Inbox(accepting: false, generation: $0.generation + 1) }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        release(active)
        active = nil
        controllerName = nil
        chordChanged(held: false)
        stopDeviceMotion()
        mixer = InputMixer(settings: settings)
        rawPad = nil; lastShown = nil; hiddenUntilReleased = 0; homeHeld = false; backHeld = false
        touchRaw = .neutral
        notePresence(false)
    }

    // MARK: seams (any thread)

    /// A pad snapshot from `from`; nil means "from the controller in use" (tests).
    nonisolated func padArrived(_ s: PadSnapshot, from id: ObjectIdentifier?) {
        post { $0.pad = (s, id) }
    }
    nonisolated func controllerMotionArrived(_ m: MotionSample, from id: ObjectIdentifier?) {
        post { $0.controllerMotion = (m, id) }
    }
    nonisolated func deviceMotionArrived(_ m: MotionSample) {
        post { $0.deviceMotion = m }
    }
    /// The on-screen controller's newest state (the whole state, never a delta).
    public nonisolated func touchArrived(_ t: TouchOutput) {
        post { $0.touch = t }
    }

    private nonisolated func post(_ put: (inout Inbox) -> Void) {
        let hop = inbox.withLockUnchecked { box -> Int? in
            guard box.accepting else { return nil }
            put(&box)
            if box.scheduled { return nil }
            box.scheduled = true
            return box.generation
        }
        guard let generation = hop else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { drain(generation) }
        }
    }

    private func drain(_ generation: Int) {
        let taken = inbox.withLock { box -> Inbox? in
            guard box.generation == generation, box.accepting else { return nil }
            let copy = box
            box.pad = nil; box.controllerMotion = nil; box.deviceMotion = nil; box.touch = nil; box.scheduled = false
            return copy
        }
        guard let taken, started else { return }
        let inUse = active.map(ObjectIdentifier.init)
        var changed = false
        let now = uptimeNs()
        if let p = taken.pad, p.from == nil || p.from == inUse {
            rawPad = p.snapshot
            edges(p.snapshot)
            let shown = forGame(p.snapshot)
            mixer.pad(shown)
            if shown != lastShown { changed = true }  // Home alone is not news to the game
            lastShown = shown
            chordChanged(held: p.snapshot.menu && p.snapshot.options)
        }
        if let t = taken.touch, !menuOpen {  // a finger that lands as the menu opens is nobody's: dropped
            touchRaw = t
            let before = mixer.current(atNs: now)
            mixer.touch(t)
            if mixer.current(atNs: now) != before { changed = true }
        }
        if let m = taken.controllerMotion, m.from == nil || m.from == inUse { mixer.controllerMotion(m.sample, atNs: now); changed = true }
        if let d = taken.deviceMotion {
            // A device sample is news only when the mode uses it.
            let before = mixer.current(atNs: now)
            mixer.deviceMotion(d, atNs: now)
            if mixer.current(atNs: now) != before { changed = true }
        }
        if changed, !menuOpen { send(mixer.current(atNs: now)) }
    }

    /// Home pressed -> `onMenuToggle`; B pressed while the menu is open -> `onBack` (once per press each).
    private func edges(_ s: PadSnapshot) {
        let homeRose = s.home && !homeHeld
        homeHeld = s.home
        let backRose = s.buttonB && !backHeld
        backHeld = s.buttonB
        if homeRose { onMenuToggle?() }
        if backRose, menuOpen { onBack?() }
    }

    /// The pad state the game may see: nothing digital while the menu is open; after it closed, not the buttons that were
    /// held then until they are let go.
    private func forGame(_ s: PadSnapshot) -> PadSnapshot {
        if menuOpen { return s.releasing(.max) }
        hiddenUntilReleased &= s.heldButtons
        return s.releasing(hiddenUntilReleased)
    }

    static let neutralInput = InputState(seq: 0, player: 0, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil)

    /// What the game is sent now: the mixer's state, neutral while the menu is open.
    private var output: InputState { menuOpen ? Self.neutralInput : mixer.current }

    private func menuChanged() {
        guard started else { return }
        if menuOpen {
            touchRaw = .neutral  // a finger the view did not release is forgotten, never held again at close
            send(Self.neutralInput)
        } else {
            mixer.touch(touchRaw)
            hiddenUntilReleased = rawPad?.heldButtons ?? 0
            if let raw = rawPad { let shown = forGame(raw); mixer.pad(shown); lastShown = shown }
            send(mixer.current)
        }
    }

    /// Sends the present state now (play begins, a reconnect completes: the Mac holds no input yet).
    public func sendCurrent() {
        guard started else { return }
        send(output)
    }

    /// Both buttons held for `menuChordHoldNs` -> `onMenuChord` once; released -> armed again.
    private func chordChanged(held: Bool) {
        guard held, settings.menuChord == .plusMinus else {
            chordTask?.cancel()
            chordTask = nil
            chordFired = false
            return
        }
        guard chordTask == nil, !chordFired else { return }
        chordTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.menuChordHoldNs)
            guard !Task.isCancelled, let self else { return }
            self.chordTask = nil
            self.chordFired = true
            self.onMenuChord?()
        }
    }

    // MARK: controllers

    /// Only a controller with the extended profile plays; the Siri Remote (a micro gamepad) is never a game controller.
    nonisolated static func isGameController(_ c: GCController) -> Bool { c.extendedGamepad != nil }

    private func controllersChanged() {
        guard started else { return }
        if active == nil { adoptBest(excluding: nil) }
        else if let cur = GCController.current, cur !== active, Self.isGameController(cur) { adopt(cur) }
    }

    private func disconnected(_ gone: ObjectIdentifier?) {
        guard started, let gone, let c = active, ObjectIdentifier(c) == gone else { return }
        release(c)
        active = nil
        controllerLost()
        adoptBest(excluding: gone)
    }

    /// The controller in use is gone: its state is forgotten and the game is sent what is left (neutral while the menu is open).
    func controllerLost() {
        controllerName = nil
        notePresence(false)
        mixer.pad(nil)
        rawPad = nil; lastShown = nil; hiddenUntilReleased = 0; homeHeld = false; backHeld = false
        chordChanged(held: false)
        send(output)
    }

    /// Applies what the inbox holds now, without waiting for the main-queue hop (tests).
    func drainNow() {
        let g = inbox.withLock { $0.generation }
        drain(g)
    }

    private func adoptBest(excluding gone: ObjectIdentifier?) {
        if let cur = GCController.current, ObjectIdentifier(cur) != gone, Self.isGameController(cur) { adopt(cur); return }
        if let c = GCController.controllers().first(where: { ObjectIdentifier($0) != gone && Self.isGameController($0) }) { adopt(c) }
    }

    /// Reports a change of "a game controller is in use" once.
    func notePresence(_ on: Bool) {
        guard on != present else { return }
        present = on
        presenceChanged?(on)
    }

    private func adopt(_ c: GCController) {
        if let old = active { release(old) }
        active = c
        notePresence(true)
        controllerName = c.vendorName
        guard let gamepad = c.extendedGamepad else { return }
        let id = ObjectIdentifier(c)
        #if os(iOS)
        gamepad.buttonHome?.preferredSystemGestureState = .disabled  // Home is the menu's while playing (UNVERIFIED on a device)
        #endif
        gamepad.valueChangedHandler = { @Sendable [weak self] g, _ in
            self?.padArrived(ControllerInput.snapshot(of: g), from: id)
        }
        let first = ControllerInput.snapshot(of: gamepad)
        rawPad = first; homeHeld = first.home; backHeld = first.buttonB
        let shown = forGame(first)
        mixer.pad(shown); lastShown = shown
        attachMotion(c)
        send(output)
    }

    private func release(_ c: GCController?) {
        guard let c else { return }
        c.extendedGamepad?.valueChangedHandler = nil
        #if os(iOS)
        c.extendedGamepad?.buttonHome?.preferredSystemGestureState = .enabled
        #endif
        if let mo = c.motion {
            mo.valueChangedHandler = nil
            if sensorsTurnedOn { mo.sensorsActive = false }
        }
        sensorsTurnedOn = false
    }

    private func attachMotion(_ c: GCController) {
        mixer.controllerMotion(nil)
        guard let mo = c.motion, mo.hasRotationRate else { return }
        if mo.sensorsRequireManualActivation { mo.sensorsActive = true; sensorsTurnedOn = true }
        let id = ObjectIdentifier(c)
        mo.valueChangedHandler = { @Sendable [weak self] m in
            self?.controllerMotionArrived(ControllerInput.sample(of: m), from: id)
        }
    }

    private nonisolated static func sample(of m: GCMotion) -> MotionSample {
        let acc: SIMD3<Float>
        if m.hasGravityAndUserAcceleration {
            acc = SIMD3(Float(m.gravity.x + m.userAcceleration.x), Float(m.gravity.y + m.userAcceleration.y),
                        Float(m.gravity.z + m.userAcceleration.z))
        } else {
            acc = SIMD3(Float(m.acceleration.x), Float(m.acceleration.y), Float(m.acceleration.z))
        }
        let rot = SIMD3(Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z))
        return MotionMapping.controller(acceleration: acc, rotation: rot)
    }

    private nonisolated static func snapshot(of g: GCExtendedGamepad) -> PadSnapshot {
        var s = PadSnapshot()
        let k = g.controller?.productCategory ?? ""
        s.usesPrintedLabels = k == "Switch Pro Controller" || k.contains("Joy-Con")
        s.buttonA = g.buttonA.isPressed; s.buttonB = g.buttonB.isPressed
        s.buttonX = g.buttonX.isPressed; s.buttonY = g.buttonY.isPressed
        s.leftShoulder = g.leftShoulder.isPressed; s.rightShoulder = g.rightShoulder.isPressed
        s.leftTrigger = g.leftTrigger.value; s.rightTrigger = g.rightTrigger.value
        s.home = g.buttonHome?.isPressed ?? false
        s.menu = g.buttonMenu.isPressed
        s.options = g.buttonOptions?.isPressed ?? false
        s.leftStick = g.leftThumbstickButton?.isPressed ?? false
        s.rightStick = g.rightThumbstickButton?.isPressed ?? false
        s.left = g.dpad.left.isPressed; s.up = g.dpad.up.isPressed
        s.right = g.dpad.right.isPressed; s.down = g.dpad.down.isPressed
        s.lx = g.leftThumbstick.xAxis.value; s.ly = g.leftThumbstick.yAxis.value
        s.rx = g.rightThumbstick.xAxis.value; s.ry = g.rightThumbstick.yAxis.value
        return s
    }

    // MARK: device motion

    private func startDeviceMotion() {
        #if os(iOS)
        guard settings.deviceMotion != .never else { return }
        let mm = CMMotionManager()
        guard mm.isDeviceMotionAvailable else { return }
        mm.deviceMotionUpdateInterval = 1.0 / 100
        motionQueue.maxConcurrentOperationCount = 1
        motionManager = mm
        mm.startDeviceMotionUpdates(to: motionQueue) { @Sendable [weak self] d, _ in
            guard let self, let d else { return }
            let acc = SIMD3(Float(d.gravity.x + d.userAcceleration.x), Float(d.gravity.y + d.userAcceleration.y),
                            Float(d.gravity.z + d.userAcceleration.z))
            let rot = SIMD3(Float(d.rotationRate.x), Float(d.rotationRate.y), Float(d.rotationRate.z))
            self.deviceMotionArrived(MotionMapping.device(orientation: self.interfaceOrientation, acceleration: acc, rotation: rot))
        }
        #endif
    }

    private func stopDeviceMotion() {
        #if os(iOS)
        motionManager?.stopDeviceMotionUpdates()
        motionManager = nil
        #endif
    }
}
