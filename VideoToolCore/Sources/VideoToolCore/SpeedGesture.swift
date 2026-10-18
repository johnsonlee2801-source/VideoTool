// SpeedGesture.swift
// Hold-and-drag speed gesture: pure logic, no AppKit, no player.
// One-to-one port of prototype/mpv-config/scripts/hold-drag-speed/gesture.lua;
// the tests in SpeedGestureTests.swift are the spec and share IDs with the Lua suite.
// Since 2026-10-19 (plan A, fixed speeds) the hold starts above the chosen speed;
// the Lua prototype keeps the original fixed 2.0x start (A-tests have no Lua twin).

import Foundation

// MARK: - Options

public struct SpeedGestureOptions: Sendable, Equatable {
    /// Seconds the button must stay down before a press counts as a hold.
    public var holdThreshold: Double = 0.25
    /// Lowest speed a hold starts at (from 1.0x the hold starts here, as before).
    public var holdSpeed: Double = 2.0
    /// A hold starts this much above the current speed, if that is higher than
    /// `holdSpeed` (decision 2026-10-19, plan A: from 2.0x a hold gives 2.5x).
    public var holdStep: Double = 0.5
    /// Slow stage: points of horizontal drag per 0.1x, both directions.
    public var pointsPerTenth: Double = 20
    /// Right of this speed the fast stage takes over.
    public var boostFromSpeed: Double = 3.0
    /// Fast stage: points per 0.1x.
    public var pointsPerTenthFast: Double = 10
    /// Horizontal movement around the origin that is ignored.
    public var deadzone: Double = 8
    public var minSpeed: Double = 0.5
    public var maxSpeed: Double = 6.0
    /// Round the live speed to 0.1 steps.
    public var snapToTenths: Bool = true
    /// Restore the pre-hold speed on release (false keeps the dragged speed).
    public var restoreOnRelease: Bool = true

    public init() {}

    public static let defaults = SpeedGestureOptions()

    /// Returns a copy with every field forced into a usable range.
    /// Same rules as `G.options` in gesture.lua.
    public func validated() -> SpeedGestureOptions {
        let d = SpeedGestureOptions.defaults
        var o = self
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
        o.holdThreshold = finite(o.holdThreshold, d.holdThreshold)
        o.holdSpeed = finite(o.holdSpeed, d.holdSpeed)
        o.holdStep = finite(o.holdStep, d.holdStep)
        if o.holdStep < 0 { o.holdStep = d.holdStep }
        o.pointsPerTenth = finite(o.pointsPerTenth, d.pointsPerTenth)
        o.boostFromSpeed = finite(o.boostFromSpeed, d.boostFromSpeed)
        o.pointsPerTenthFast = finite(o.pointsPerTenthFast, d.pointsPerTenthFast)
        o.deadzone = finite(o.deadzone, d.deadzone)
        o.minSpeed = finite(o.minSpeed, d.minSpeed)
        o.maxSpeed = finite(o.maxSpeed, d.maxSpeed)

        if o.pointsPerTenth <= 0 { o.pointsPerTenth = d.pointsPerTenth }
        if o.pointsPerTenthFast <= 0 { o.pointsPerTenthFast = d.pointsPerTenthFast }
        if o.deadzone < 0 { o.deadzone = d.deadzone }
        if o.holdThreshold < 0 { o.holdThreshold = d.holdThreshold }
        if !(o.minSpeed > 0 && o.minSpeed < o.maxSpeed) {
            o.minSpeed = d.minSpeed
            o.maxSpeed = d.maxSpeed
        }
        o.holdSpeed = min(max(o.holdSpeed, o.minSpeed), o.maxSpeed)
        // The fast stage only makes sense between the hold speed and the cap;
        // anything else disables it by moving the boost point to the cap.
        if !(o.boostFromSpeed >= o.holdSpeed && o.boostFromSpeed <= o.maxSpeed) {
            o.boostFromSpeed = o.maxSpeed
        }
        return o
    }

    /// Where a hold starts when playback runs at `current`: `current + holdStep`,
    /// never below `holdSpeed`, never above `maxSpeed`, on 0.1 steps.
    public func holdStart(from current: Double) -> Double {
        let raw = max(holdSpeed, (current.isFinite ? current : 1) + holdStep)
        let snapped = snapToTenths ? (raw * 10 + 0.5 + 1e-9).rounded(.down) / 10 : raw
        return min(max(snapped, minSpeed), maxSpeed)
    }
}

// MARK: - Curve

public enum SpeedCurve {
    /// Maps horizontal drag distance (points, right positive) to playback speed.
    /// Default curve, right of the origin after the deadzone:
    ///   2.0x --(200 pt, 20 pt per 0.1x)--> 3.0x --(300 pt, 10 pt per 0.1x)--> 6.0x
    /// Left of the origin: 20 pt per 0.1x down to 0.5x.
    /// `origin` is the speed at zero drag (the hold's start speed; default `holdSpeed`).
    /// Starting at or above the boost point, a right drag is on the fast slope at once.
    public static func speed(forDrag dx: Double, options o: SpeedGestureOptions, origin: Double? = nil) -> Double {
        let origin = origin ?? o.holdSpeed
        let dz = o.deadzone
        var effective = 0.0
        if dx > dz { effective = dx - dz } else if dx < -dz { effective = dx + dz }

        var speed: Double
        // Points needed to climb from the origin to the boost point on the slow slope.
        let slowPoints = max(0, o.boostFromSpeed - origin) * 10 * o.pointsPerTenth
        if effective > slowPoints {
            speed = max(origin, o.boostFromSpeed) + ((effective - slowPoints) / o.pointsPerTenthFast) * 0.1
        } else {
            speed = origin + (effective / o.pointsPerTenth) * 0.1
        }
        if o.snapToTenths {
            // 1e-9 guards against 2.05*10 landing on 20.4999999 in binary floats.
            speed = (speed * 10 + 0.5 + 1e-9).rounded(.down) / 10
        }
        return min(max(speed, o.minSpeed), o.maxSpeed)
    }
}

// MARK: - Host

/// What the machine needs from the player and the screen. The app implements
/// this on top of the player engine; tests use a recording fake.
public protocol SpeedGestureHost: AnyObject {
    var speed: Double { get }
    func setSpeed(_ speed: Double)
    var isPaused: Bool { get }
    func setPaused(_ paused: Bool)
    func togglePause()
    func show(speed: Double, dx: Double)
    func hide()
    /// Current pointer x in points, nil if unknown.
    var mouseX: Double? { get }
}

// MARK: - Machine

/// Hold / drag state machine. Feed it `mouseDown`, `tick` (while pressed, ~60 Hz),
/// `mouseUp`, and `cancel` when the press is taken away (key press, focus loss).
public final class SpeedGestureMachine {
    public let options: SpeedGestureOptions
    private weak var host: (any SpeedGestureHost)?

    public private(set) var isHolding = false
    /// Button is down (before or during the hold). Keys pressed now cancel the gesture.
    public var isPressed: Bool { pressed }
    private var pressed = false
    private var downAt: Double = 0
    private var startX: Double?          // first pointer sample seen during the hold
    private var savedSpeed: Double = 1.0
    private var origin: Double = 2.0      // this hold's start speed
    private var current: Double?
    private var shown: (speed: Double, dx: Double)?

    public init(options: SpeedGestureOptions = .defaults, host: any SpeedGestureHost) {
        self.options = options.validated()
        self.host = host
    }

    public func mouseDown(at now: Double) {
        guard !pressed else { return }
        pressed = true
        downAt = now
    }

    public func tick(at now: Double) {
        guard pressed, let host else { return }
        if !isHolding {
            if now - downAt >= options.holdThreshold { beginHold(host) }
            return
        }
        let x = host.mouseX
        if startX == nil { startX = x }
        var dx = 0.0
        if let x, let startX { dx = x - startX }
        apply(SpeedCurve.speed(forDrag: dx, options: options, origin: origin), host)
        draw(speed: current ?? origin, dx: dx, host)
    }

    public func mouseUp(at now: Double) {
        guard pressed, let host else { pressed = false; return }
        pressed = false
        if isHolding {
            endHold(host)
        } else {
            host.togglePause()
        }
    }

    /// The press was taken away from us (another key went down, focus was lost,
    /// the file ended). Never a tap.
    public func cancel() {
        if isHolding, let host { endHold(host) }
        isHolding = false
        pressed = false
    }

    public func fileEnded() { cancel() }

    // MARK: private

    private func apply(_ speed: Double, _ host: any SpeedGestureHost) {
        if speed != current {
            current = speed
            host.setSpeed(speed)
        }
    }

    /// Redraw only when something visible changed (speed or the px read-out).
    private func draw(speed: Double, dx: Double, _ host: any SpeedGestureHost) {
        if shown?.speed != speed || shown?.dx != dx {
            shown = (speed, dx)
            host.show(speed: speed, dx: dx)
        }
    }

    private func beginHold(_ host: any SpeedGestureHost) {
        isHolding = true
        startX = host.mouseX                 // may be nil; first later sample wins
        savedSpeed = host.speed
        origin = options.holdStart(from: savedSpeed)
        current = nil
        shown = nil
        // Decision: a hold always moves forward, and release does not re-pause.
        if host.isPaused { host.setPaused(false) }
        apply(origin, host)
        draw(speed: origin, dx: 0, host)
    }

    private func endHold(_ host: any SpeedGestureHost) {
        isHolding = false
        host.hide()
        if options.restoreOnRelease { apply(savedSpeed, host) }
    }
}
