// Port of prototype/tests/test_gesture.lua, case for case.
// Test IDs (S/O/M) match the Lua suite so the two can be diffed.
import Testing
@testable import VideoToolCore

private let D = SpeedGestureOptions.defaults   // hold 2.0, 20pt/0.1x to 3.0, then 10pt/0.1x to 6.0, deadzone 8, min 0.5, snap on, threshold 0.25

private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

private func opts(_ edit: (inout SpeedGestureOptions) -> Void) -> SpeedGestureOptions {
    var o = SpeedGestureOptions.defaults
    edit(&o)
    return o.validated()
}

// MARK: - Fake host (mirror of tests/fake_io.lua)

final class FakeHost: SpeedGestureHost {
    var speed: Double
    var isPaused: Bool
    var mouseX: Double?
    private(set) var setSpeedCount = 0
    private(set) var toggleCount = 0
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var setPauseCalls: [Bool] = []
    private(set) var lastShow: (speed: Double, dx: Double)?

    init(speed: Double = 1.0, paused: Bool = false, x: Double? = 500) {
        self.speed = speed; self.isPaused = paused; self.mouseX = x
    }
    func setSpeed(_ v: Double) { setSpeedCount += 1; speed = v }
    func setPaused(_ p: Bool) { setPauseCalls.append(p); isPaused = p }
    func togglePause() { toggleCount += 1; isPaused.toggle() }
    func show(speed: Double, dx: Double) { showCount += 1; lastShow = (speed, dx) }
    func hide() { hideCount += 1 }
}

private func machine(_ options: SpeedGestureOptions = D, speed: Double = 1.0, paused: Bool = false, x: Double? = 500)
    -> (SpeedGestureMachine, FakeHost) {
    let h = FakeHost(speed: speed, paused: paused, x: x)
    return (SpeedGestureMachine(options: options, host: h), h)
}

// MARK: - speed(forDrag:)

@Suite struct SpeedCurveTests {
    @Test("S1 no drag gives hold_speed") func s1() { #expect(near(SpeedCurve.speed(forDrag: 0, options: D), 2.0)) }
    @Test("S2 drag inside deadzone (+8) still hold_speed") func s2() { #expect(near(SpeedCurve.speed(forDrag: 8, options: D), 2.0)) }
    @Test("S3 drag inside deadzone (-8) still hold_speed") func s3() { #expect(near(SpeedCurve.speed(forDrag: -8, options: D), 2.0)) }
    @Test("S4 one step right: deadzone + 20pt = +0.1") func s4() { #expect(near(SpeedCurve.speed(forDrag: 28, options: D), 2.1)) }
    @Test("S5 one step left: -(deadzone + 20pt) = -0.1") func s5() { #expect(near(SpeedCurve.speed(forDrag: -28, options: D), 1.9)) }
    @Test("S6 ten steps right (deadzone + 200pt) reaches 3.0") func s6() { #expect(near(SpeedCurve.speed(forDrag: 208, options: D), 3.0)) }
    @Test("S7 far right clamps at max_speed 6.0") func s7() { #expect(near(SpeedCurve.speed(forDrag: 5000, options: D), 6.0)) }
    @Test("S8 far left clamps at min_speed") func s8() { #expect(near(SpeedCurve.speed(forDrag: -5000, options: D), 0.5)) }
    @Test("S9 snap off gives continuous value") func s9() {
        let o = opts { $0.snapToTenths = false }
        #expect(near(SpeedCurve.speed(forDrag: 18, options: o), 2.05))
    }
    @Test("S10 snap on rounds to nearest tenth") func s10() {
        #expect(near(SpeedCurve.speed(forDrag: 18, options: D), 2.1))
        #expect(near(SpeedCurve.speed(forDrag: 17, options: D), 2.0))
    }
    @Test("S11 custom hold_speed is the drag origin") func s11() {
        let o = opts { $0.holdSpeed = 1.5 }
        #expect(near(SpeedCurve.speed(forDrag: 0, options: o), 1.5))
        #expect(near(SpeedCurve.speed(forDrag: 28, options: o), 1.6))
    }
    @Test("S12 speed is monotonic non-decreasing in dx") func s12() {
        var prev = -Double.infinity
        for dx in -800...800 {
            let s = SpeedCurve.speed(forDrag: Double(dx), options: D)
            #expect(s >= prev - 1e-9, "dropped at dx=\(dx): \(s) < \(prev)")
            prev = s
        }
    }
    @Test("S13 result never leaves [min_speed, max_speed]") func s13() {
        for dx in stride(from: -100_000, through: 100_000, by: 997) {
            let s = SpeedCurve.speed(forDrag: Double(dx), options: D)
            #expect(s >= 0.5 && s <= 6.0, "out of range at dx=\(dx): \(s)")
        }
    }
    @Test("S14 snapped output is always a multiple of 0.1") func s14() {
        for dx in -800...800 {
            let s = SpeedCurve.speed(forDrag: Double(dx), options: D)
            #expect(near(s * 10, (s * 10 + 0.5).rounded(.down), 1e-6), "dx=\(dx)")
        }
    }
    @Test("S15 slow-stage slope law with snap off: 20pt further out is exactly 0.1 more") func s15() {
        let o = opts { $0.snapToTenths = false }
        for dx in stride(from: 8.0, through: 130.0, by: 7.0) {
            #expect(near(SpeedCurve.speed(forDrag: dx + 20, options: o) - SpeedCurve.speed(forDrag: dx, options: o), 0.1), "dx=\(dx)")
            #expect(near(SpeedCurve.speed(forDrag: -dx - 20, options: o) - SpeedCurve.speed(forDrag: -dx, options: o), -0.1), "dx=-\(dx)")
        }
    }
    @Test("S16 odd symmetry about the origin inside the slow stage") func s16() {
        let o = opts { $0.snapToTenths = false }
        for dx in stride(from: 0.0, through: 150.0, by: 13.0) {
            #expect(near(SpeedCurve.speed(forDrag: dx, options: o) - 2.0, -(SpeedCurve.speed(forDrag: -dx, options: o) - 2.0)), "dx=\(dx)")
        }
    }
    @Test("S17 curve is continuous at the boost point: 208pt = 3.0, next 10pt = 3.1") func s17() {
        #expect(near(SpeedCurve.speed(forDrag: 208, options: D), 3.0))
        #expect(near(SpeedCurve.speed(forDrag: 218, options: D), 3.1))
        let o = opts { $0.snapToTenths = false }
        #expect(near(SpeedCurve.speed(forDrag: 208, options: o), 3.0))
        #expect(near(SpeedCurve.speed(forDrag: 209, options: o), 3.01))
    }
    @Test("S18 fast-stage slope law with snap off: 10pt further out is exactly 0.1 more") func s18() {
        let o = opts { $0.snapToTenths = false }
        for dx in stride(from: 208.0, through: 490.0, by: 6.0) {
            #expect(near(SpeedCurve.speed(forDrag: dx + 10, options: o) - SpeedCurve.speed(forDrag: dx, options: o), 0.1), "dx=\(dx)")
        }
    }
    @Test("S19 6.0 is reached at 8 + 200 + 300 = 508pt and not before") func s19() {
        let o = opts { $0.snapToTenths = false }
        #expect(SpeedCurve.speed(forDrag: 507, options: o) < 6.0)
        #expect(near(SpeedCurve.speed(forDrag: 508, options: o), 6.0))
        #expect(near(SpeedCurve.speed(forDrag: 800, options: o), 6.0))
        #expect(near(SpeedCurve.speed(forDrag: 508, options: D), 6.0))
    }
    @Test("S20 halfway to the old 3.0 distance now gives 3.0") func s20() { #expect(near(SpeedCurve.speed(forDrag: 208, options: D), 3.0)) }
    @Test("S21 left side is unaffected by the boost stage") func s21() {
        let o = opts { $0.snapToTenths = false }
        #expect(near(SpeedCurve.speed(forDrag: -108, options: o), 1.5))
        #expect(near(SpeedCurve.speed(forDrag: -308, options: o), 0.5))
    }
}

// MARK: - Option validation

@Suite struct SpeedGestureOptionsTests {
    @Test("O1 pointsPerTenth <= 0 falls back to default instead of dividing by zero") func o1() {
        let o = opts { $0.pointsPerTenth = 0 }
        #expect(o.pointsPerTenth == D.pointsPerTenth)
        #expect(near(SpeedCurve.speed(forDrag: 28, options: o), 2.1))
    }
    @Test("O2 minSpeed above maxSpeed is rejected, defaults kept") func o2() {
        let o = opts { $0.minSpeed = 3.0; $0.maxSpeed = 1.0 }
        #expect(o.minSpeed == D.minSpeed)
        #expect(o.maxSpeed == D.maxSpeed)
    }
    @Test("O3 holdSpeed outside [min,max] is clamped into range") func o3() {
        let o = opts { $0.holdSpeed = 9.0 }
        #expect(near(o.holdSpeed, D.maxSpeed))
    }
    @Test("O4 validated() does not mutate defaults") func o4() {
        _ = opts { $0.holdSpeed = 1.1; $0.pointsPerTenth = 10 }
        #expect(near(SpeedGestureOptions.defaults.holdSpeed, 2.0))
        #expect(SpeedGestureOptions.defaults.pointsPerTenth == 20)
    }
    @Test("O5 non-finite values fall back to defaults") func o5() {
        let o = opts { $0.holdThreshold = .infinity; $0.maxSpeed = .infinity; $0.minSpeed = -.infinity; $0.deadzone = .nan }
        #expect(o.holdThreshold == D.holdThreshold)
        #expect(o.maxSpeed == D.maxSpeed)
        #expect(o.minSpeed == D.minSpeed)
        #expect(o.deadzone == D.deadzone)
    }
    @Test("O6 boostFromSpeed outside [holdSpeed, maxSpeed] disables the fast stage") func o6() {
        let o = opts { $0.boostFromSpeed = 9.0; $0.snapToTenths = false }
        #expect(near(o.boostFromSpeed, D.maxSpeed))
        #expect(near(SpeedCurve.speed(forDrag: 308, options: o), 3.5))
        let o2 = opts { $0.boostFromSpeed = 1.0; $0.snapToTenths = false }
        #expect(near(o2.boostFromSpeed, D.maxSpeed))
    }
    @Test("O7 pointsPerTenthFast <= 0 falls back to default") func o7() {
        let o = opts { $0.pointsPerTenthFast = 0 }
        #expect(o.pointsPerTenthFast == D.pointsPerTenthFast)
        #expect(near(SpeedCurve.speed(forDrag: 218, options: o), 3.1))
    }
    @Test("O8 boostFromSpeed equal to holdSpeed means fast slope from the start") func o8() {
        let o = opts { $0.boostFromSpeed = 2.0; $0.snapToTenths = false }
        #expect(near(SpeedCurve.speed(forDrag: 18, options: o), 2.1))
    }
    @Test("O9 negative deadzone and threshold fall back to defaults") func o9() {
        let o = opts { $0.deadzone = -1; $0.holdThreshold = -1 }
        #expect(o.deadzone == D.deadzone)
        #expect(o.holdThreshold == D.holdThreshold)
    }
}

// MARK: - Hold / drag machine

@Suite struct SpeedGestureMachineTests {
    @Test("M1 tap (release before threshold) toggles pause, never touches speed") func m1() {
        let (m, f) = machine()
        m.mouseDown(at: 0); m.tick(at: 0.10); m.mouseUp(at: 0.20)
        #expect(f.toggleCount == 1); #expect(f.setSpeedCount == 0); #expect(f.showCount == 0); #expect(m.isHolding == false)
    }
    @Test("M2 hold past threshold sets hold_speed and shows OSD once") func m2() {
        let (m, f) = machine()
        m.mouseDown(at: 0); m.tick(at: 0.30)
        #expect(m.isHolding); #expect(near(f.speed, 2.0)); #expect(f.setSpeedCount == 1); #expect(f.toggleCount == 0)
        #expect(f.lastShow?.speed == 2.0); #expect(f.lastShow?.dx == 0); #expect(f.showCount == 1)
    }
    @Test("M3 hold while paused unpauses") func m3() {
        let (m, f) = machine(paused: true)
        m.mouseDown(at: 0); m.tick(at: 0.30)
        #expect(f.isPaused == false)
    }
    @Test("M4 hold while playing does not call setPaused") func m4() {
        let (m, f) = machine()
        m.mouseDown(at: 0); m.tick(at: 0.30)
        #expect(f.setPauseCalls.isEmpty)
    }
    @Test("M5 drag right 80pt gives 2.4") func m5() {
        let (m, f) = machine(x: 500)
        m.mouseDown(at: 0); m.tick(at: 0.30)
        f.mouseX = 580; m.tick(at: 0.35)
        #expect(near(f.speed, 2.4)); #expect(f.lastShow?.dx == 80)
    }
    @Test("M6 drag far left clamps to min_speed") func m6() {
        let (m, f) = machine(x: 2000)
        m.mouseDown(at: 0); m.tick(at: 0.30)
        f.mouseX = 0; m.tick(at: 0.35)
        #expect(near(f.speed, 0.5))
    }
    @Test("M7 release restores the pre-hold speed and hides OSD") func m7() {
        let (m, f) = machine(speed: 1.25)
        m.mouseDown(at: 0); m.tick(at: 0.30)
        f.mouseX = 700; m.tick(at: 0.40)
        m.mouseUp(at: 0.50)
        #expect(near(f.speed, 1.25)); #expect(f.hideCount == 1); #expect(f.toggleCount == 0); #expect(m.isHolding == false)
    }
    @Test("M8 restoreOnRelease=false keeps the dragged speed") func m8() {
        let (m, f) = machine(opts { $0.restoreOnRelease = false }, speed: 1.0, x: 100)
        m.mouseDown(at: 0); m.tick(at: 0.30)
        f.mouseX = 300; m.tick(at: 0.40)
        let before = f.setSpeedCount
        m.mouseUp(at: 0.50)
        #expect(near(f.speed, 3.0)); #expect(f.setSpeedCount == before); #expect(f.hideCount == 1)
    }
    @Test("M9 unchanged dx across ticks does not re-issue setSpeed") func m9() {
        let (m, f) = machine()
        m.mouseDown(at: 0); m.tick(at: 0.30)
        let n = f.setSpeedCount
        m.tick(at: 0.32); m.tick(at: 0.34); m.tick(at: 0.36)
        #expect(f.setSpeedCount == n)
    }
    @Test("M10 small jitter inside deadzone does not change speed") func m10() {
        let (m, f) = machine(x: 500)
        m.mouseDown(at: 0); m.tick(at: 0.30)
        let n = f.setSpeedCount
        f.mouseX = 505; m.tick(at: 0.32)
        f.mouseX = 496; m.tick(at: 0.34)
        #expect(f.setSpeedCount == n); #expect(near(f.speed, 2.0))
    }
    @Test("M11 up without down is a no-op") func m11() {
        let (m, f) = machine()
        m.mouseUp(at: 1.0)
        #expect(f.toggleCount == 0); #expect(f.setSpeedCount == 0); #expect(f.hideCount == 0)
    }
    @Test("M12 tick after an early release never starts a hold") func m12() {
        let (m, f) = machine()
        m.mouseDown(at: 0); m.mouseUp(at: 0.10); m.tick(at: 0.50); m.tick(at: 1.0)
        #expect(f.setSpeedCount == 0); #expect(m.isHolding == false)
    }
    @Test("M13 tick without any press is a no-op") func m13() {
        let (m, f) = machine()
        m.tick(at: 5.0)
        #expect(f.setSpeedCount == 0); #expect(f.showCount == 0)
    }
    @Test("M14 file end during hold cleans up; following up does not toggle") func m14() {
        let (m, f) = machine(speed: 1.0)
        m.mouseDown(at: 0); m.tick(at: 0.30)
        m.fileEnded()
        #expect(near(f.speed, 1.0)); #expect(f.hideCount == 1); #expect(m.isHolding == false)
        m.mouseUp(at: 0.40)
        #expect(f.toggleCount == 0)
    }
    @Test("M15 release exactly at threshold with no tick in between counts as tap") func m15() {
        let (m, f) = machine()
        m.mouseDown(at: 0); m.mouseUp(at: 0.25)
        #expect(f.toggleCount == 1); #expect(f.setSpeedCount == 0)
    }
    @Test("M16 threshold boundary: tick at exactly threshold starts the hold") func m16() {
        // The machine holds its host weakly, so the test must keep the fake alive.
        let (m, f) = machine()
        withExtendedLifetime(f) {
            m.mouseDown(at: 0); m.tick(at: 0.25)
            #expect(m.isHolding)
        }
    }
    @Test("M17 second gesture after a full cycle starts clean from the new origin") func m17() {
        let (m, f) = machine(x: 100)
        m.mouseDown(at: 0); m.tick(at: 0.30); f.mouseX = 300; m.tick(at: 0.40); m.mouseUp(at: 0.50)
        #expect(near(f.speed, 1.0))
        f.mouseX = 900
        m.mouseDown(at: 1.0); m.tick(at: 1.30)
        #expect(near(f.speed, 2.0)); #expect(f.lastShow?.dx == 0)
    }
    @Test("M18 second down while already pressed is ignored (no origin reset)") func m18() {
        let (m, f) = machine(x: 100)
        m.mouseDown(at: 0); m.tick(at: 0.30); f.mouseX = 180
        m.mouseDown(at: 0.35); m.tick(at: 0.40)
        #expect(near(f.speed, 2.4))
    }
    @Test("M19 drag during the pre-threshold window does not pre-set the origin") func m19() {
        let (m, f) = machine(x: 100)
        m.mouseDown(at: 0); f.mouseX = 400; m.tick(at: 0.10); m.tick(at: 0.30)
        #expect(near(f.speed, 2.0)); #expect(f.lastShow?.dx == 0)
    }
    @Test("M20 cancel during hold restores speed, hides OSD, never toggles pause") func m20() {
        let (m, f) = machine(speed: 1.5)
        m.mouseDown(at: 0); m.tick(at: 0.3); f.mouseX = 700; m.tick(at: 0.4)
        m.cancel()
        #expect(f.toggleCount == 0); #expect(near(f.speed, 1.5)); #expect(f.hideCount == 1); #expect(m.isHolding == false)
        m.mouseUp(at: 0.5)
        #expect(f.toggleCount == 0)
    }
    @Test("M21 cancel before threshold is neither tap nor hold") func m21() {
        let (m, f) = machine()
        m.mouseDown(at: 0); m.cancel(); m.tick(at: 0.5)
        #expect(f.toggleCount == 0); #expect(f.setSpeedCount == 0); #expect(m.isHolding == false)
    }
    @Test("M22 hold on a paused file leaves it playing after release (documented decision)") func m22() {
        let (m, f) = machine(paused: true)
        m.mouseDown(at: 0); m.tick(at: 0.3); m.mouseUp(at: 0.4)
        #expect(f.isPaused == false); #expect(f.toggleCount == 0)
    }
    @Test("M23 identical ticks do not redraw the OSD; a dx change does") func m23() {
        let (m, f) = machine(x: 500)
        m.mouseDown(at: 0); m.tick(at: 0.3)
        let n = f.showCount
        m.tick(at: 0.32); m.tick(at: 0.34); m.tick(at: 0.36)
        #expect(f.showCount == n)
        f.mouseX = 505; m.tick(at: 0.38)
        #expect(f.showCount == n + 1); #expect(near(f.speed, 2.0))
    }
    @Test("M24 holdThreshold=0 starts the hold on the first tick") func m24() {
        let (m, f) = machine(opts { $0.holdThreshold = 0 })
        withExtendedLifetime(f) {
            m.mouseDown(at: 0); m.tick(at: 0)
            #expect(m.isHolding)
        }
    }
    @Test("M28 host released: ticks and releases become no-ops without crashing") func m28() {
        var f: FakeHost? = FakeHost()
        let m = SpeedGestureMachine(options: D, host: f!)
        m.mouseDown(at: 0)
        f = nil
        m.tick(at: 0.5); m.mouseUp(at: 0.6); m.cancel()
        #expect(m.isHolding == false)
    }
    @Test("M30 host released during a hold: the release ends the hold") func m30() {
        var f: FakeHost? = FakeHost()
        let m = SpeedGestureMachine(options: D, host: f!)
        m.mouseDown(at: 0); m.tick(at: 0.3)
        #expect(m.isHolding)
        f = nil
        m.mouseUp(at: 0.6)
        #expect(m.isHolding == false)
    }
    @Test("M25 file end with no press is a no-op") func m25() {
        let (m, f) = machine()
        m.fileEnded()
        #expect(f.hideCount == 0); #expect(f.setSpeedCount == 0)
    }
    @Test("M26 round trip: release restores the start speed for any drag and any start speed") func m26() {
        for s0 in [0.5, 1.0, 1.75, 3.0] {
            for dx in [-1000.0, -100, 0, 37, 250, 2000] {
                let (m, f) = machine(speed: s0, x: 1000)
                m.mouseDown(at: 0); m.tick(at: 0.3); f.mouseX = 1000 + dx; m.tick(at: 0.4); m.mouseUp(at: 0.5)
                #expect(near(f.speed, s0), "s0=\(s0) dx=\(dx)")
            }
        }
    }
    @Test("M27 origin comes from the first available mouse sample, not from 0") func m27() {
        let (m, f) = machine(x: nil)
        m.mouseDown(at: 0); m.tick(at: 0.3)
        #expect(near(f.speed, 2.0))
        f.mouseX = 800; m.tick(at: 0.35)
        #expect(near(f.speed, 2.0))
        f.mouseX = 880; m.tick(at: 0.40)
        #expect(near(f.speed, 2.4))
    }

    @Test("M29 isPressed tracks the button from down to up or cancel, independent of the hold") func m29() {
        let (m, f) = machine()
        withExtendedLifetime(f) {
            #expect(!m.isPressed)
            m.mouseDown(at: 0); #expect(m.isPressed); #expect(!m.isHolding)
            m.tick(at: 0.3); #expect(m.isPressed); #expect(m.isHolding)
            m.mouseUp(at: 0.4); #expect(!m.isPressed)
            m.mouseDown(at: 1); m.cancel(); #expect(!m.isPressed)
        }
    }

    // MARK: plan A (decision 2026-10-19): the hold starts above the chosen speed

    @Test("A1 hold start = current speed + 0.5, never below 2.0, capped at 6.0") func a1() {
        let o = SpeedGestureOptions.defaults
        for (base, start) in [(1.0, 2.0), (0.75, 2.0), (1.5, 2.0), (2.0, 2.5), (2.5, 3.0), (3.0, 3.5), (5.8, 6.0), (6.0, 6.0)] {
            #expect(near(o.holdStart(from: base), start), "base \(base)")
        }
    }
    @Test("A2 a hold from 2.0x starts at 2.5x and release returns to 2.0x") func a2() {
        let (m, f) = machine(speed: 2.0, x: 1000)
        m.mouseDown(at: 0); m.tick(at: 0.3)
        #expect(near(f.speed, 2.5))
        m.mouseUp(at: 0.5)
        #expect(near(f.speed, 2.0))
    }
    @Test("A3 dragging continues from the raised start: +20pt after the deadzone is +0.1") func a3() {
        let (m, f) = machine(speed: 2.0, x: 1000)
        m.mouseDown(at: 0); m.tick(at: 0.3)
        f.mouseX = 1028; m.tick(at: 0.4)
        #expect(near(f.speed, 2.6))
        f.mouseX = 1000 - 28; m.tick(at: 0.5)
        #expect(near(f.speed, 2.4))
    }
    @Test("A4 from 1.0x nothing changes: the hold still starts at 2.0x") func a4() {
        let (m, f) = machine(speed: 1.0, x: 1000)
        m.mouseDown(at: 0); m.tick(at: 0.3)
        #expect(near(f.speed, 2.0))
    }
    @Test("A5 above the boost point the drag goes straight to the fast slope (10pt per 0.1)") func a5() {
        let o = SpeedGestureOptions.defaults
        #expect(near(SpeedCurve.speed(forDrag: 0, options: o, origin: 3.5), 3.5))
        #expect(near(SpeedCurve.speed(forDrag: 18, options: o, origin: 3.5), 3.6))
        #expect(near(SpeedCurve.speed(forDrag: -28, options: o, origin: 3.5), 3.4))
        #expect(near(SpeedCurve.speed(forDrag: 5000, options: o, origin: 3.5), 6.0))
    }
    @Test("A6 from 2.5x the slow stage runs to 3.0 then turns fast, with no jump") func a6() {
        let o = SpeedGestureOptions.defaults
        #expect(near(SpeedCurve.speed(forDrag: 18, options: o, origin: 3.0), 3.1))
        #expect(near(SpeedCurve.speed(forDrag: 108, options: o, origin: 2.5), 3.0))
        #expect(near(SpeedCurve.speed(forDrag: 118, options: o, origin: 2.5), 3.1))
    }
    @Test("A7 the curve with the default origin is the old curve") func a7() {
        let o = SpeedGestureOptions.defaults
        for dx in stride(from: -600.0, through: 800, by: 7) {
            #expect(near(SpeedCurve.speed(forDrag: dx, options: o, origin: o.holdSpeed), SpeedCurve.speed(forDrag: dx, options: o)))
        }
    }
    @Test("A8 holdStep is validated: negative or non-finite falls back to 0.5") func a8() {
        var o = SpeedGestureOptions(); o.holdStep = -1
        #expect(near(o.validated().holdStep, 0.5))
        o.holdStep = .nan
        #expect(near(o.validated().holdStep, 0.5))
    }
}
