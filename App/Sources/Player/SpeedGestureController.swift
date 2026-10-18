import Foundation
import QuartzCore
import VideoToolCore

/// Drives `tick` while the button is held. Real one is a 60 Hz timer; tests fire by hand.
protocol TickScheduler: AnyObject {
    func start(interval: Double, handler: @escaping () -> Void)
    func stop()
}

final class TimerTickScheduler: TickScheduler {
    private var timer: Timer?
    func start(interval: Double, handler: @escaping () -> Void) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { _ in handler() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }
}

/// On-screen feedback for the gesture.
protocol SpeedHUD: AnyObject {
    func show(speed: Double, dx: Double)
    func hide()
    /// Brief "back to 1.0x" style confirmation after release.
    func flash(speed: Double)
}

/// Glue between AppKit mouse events, the pure `SpeedGestureMachine`, the player
/// engine and the HUD. Mirrors main.lua in the mpv prototype.
final class SpeedGestureController {
    static let pollInterval = 1.0 / 60.0

    private let engine: PlayerEngine
    private let hud: SpeedHUD
    private let scheduler: TickScheduler
    private let clock: () -> Double
    private let mouseXProvider: () -> Double?
    private var machine: SpeedGestureMachine!
    private var lastSetSpeed: Double?

    init(engine: PlayerEngine,
         hud: SpeedHUD,
         scheduler: TickScheduler = TimerTickScheduler(),
         options: SpeedGestureOptions = .defaults,
         clock: @escaping () -> Double = { CACurrentMediaTime() },
         mouseX: @escaping () -> Double?) {
        self.engine = engine
        self.hud = hud
        self.scheduler = scheduler
        self.clock = clock
        self.mouseXProvider = mouseX
        self.machine = SpeedGestureMachine(options: options, host: self)
    }

    var isHolding: Bool { machine.isHolding }
    /// Button down, before or during the hold. A key press now cancels the gesture.
    var isActive: Bool { machine.isPressed || machine.isHolding }

    func mouseDown() {
        machine.mouseDown(at: clock())
        scheduler.start(interval: Self.pollInterval) { [weak self] in
            guard let self else { return }
            self.machine.tick(at: self.clock())
        }
    }

    func mouseUp() {
        scheduler.stop()
        let wasHolding = machine.isHolding
        machine.mouseUp(at: clock())
        if wasHolding { hud.flash(speed: lastSetSpeed ?? engine.state.speed) }
    }

    /// Key press, focus loss, file end: end the hold without a tap.
    func cancel() {
        scheduler.stop()
        machine.cancel()
    }
}

extension SpeedGestureController: SpeedGestureHost {
    var speed: Double { engine.state.speed }
    func setSpeed(_ speed: Double) { lastSetSpeed = speed; engine.setSpeed(speed) }
    var isPaused: Bool { engine.state.isPaused }
    func setPaused(_ paused: Bool) { engine.setPaused(paused) }
    func togglePause() { engine.togglePause() }
    func show(speed: Double, dx: Double) { hud.show(speed: speed, dx: dx) }
    func hide() { hud.hide() }
    var mouseX: Double? { mouseXProvider() }
}
