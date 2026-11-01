import Foundation
import Testing
import VideoToolCore
@testable import VideoTool

// Swift counterpart of the prototype's test_adapter.lua: the controller is
// driven with a fake engine, fake HUD, hand-fired scheduler and fake clock.

final class FakeEngine: PlayerEngine {
    var state = PlayerState(isPaused: false, speed: 1.0)
    var onStateChange: ((PlayerState) -> Void)?
    var onEvent: ((PlayerEvent) -> Void)?
    var setSpeedCalls: [Double] = []
    var togglePauseCount = 0
    var setPausedCalls: [Bool] = []

    func load(_ url: URL) {}
    func stop() {}
    func setPaused(_ paused: Bool) { setPausedCalls.append(paused); state.isPaused = paused }
    func togglePause() { togglePauseCount += 1; state.isPaused.toggle() }
    var seeks: [Double] = []
    func seek(to seconds: Double) { seeks.append(seconds) }
    func seek(by delta: Double) {}
    func scrub(to seconds: Double) {}
    func setSpeed(_ speed: Double) { setSpeedCalls.append(speed); state.speed = speed }
    func setVolume(_ volume: Double) {}
    func toggleMute() {}
    func cycleSubtitle() {}
    func cycleAudio() {}
}

final class FakeHUD: SpeedHUD {
    var shows: [(speed: Double, dx: Double)] = []
    var hideCount = 0
    var flashes: [Double] = []
    func show(speed: Double, dx: Double) { shows.append((speed, dx)) }
    func hide() { hideCount += 1 }
    func flash(speed: Double) { flashes.append(speed) }
}

final class FakeScheduler: TickScheduler {
    var handler: (() -> Void)?
    var startCount = 0
    var isRunning: Bool { handler != nil }
    func start(interval: Double, handler: @escaping () -> Void) { startCount += 1; self.handler = handler }
    func stop() { handler = nil }
    func fire() { handler?() }
}

@MainActor
private final class Rig {
    let engine = FakeEngine()
    let hud = FakeHUD()
    let scheduler = FakeScheduler()
    var now = 0.0
    var mouseX: Double? = 500
    var doubleClickInterval = 0.5
    lazy var controller = SpeedGestureController(engine: engine, hud: hud, scheduler: scheduler,
                                                 doubleClickInterval: doubleClickInterval,
                                                 clock: { [unowned self] in self.now },
                                                 mouseX: { [unowned self] in self.mouseX })
    func press() { controller.mouseDown() }
    func release() { controller.mouseUp() }
    func advance(_ dt: Double) { now += dt; scheduler.fire() }
}

@Suite @MainActor struct SpeedGestureControllerTests {
    @Test("A1 press starts exactly one poll timer") func pressStartsTimer() {
        let r = Rig()
        r.press()
        #expect(r.scheduler.isRunning); #expect(r.scheduler.startCount == 1)
    }

    @Test("A2 hold past threshold sets 2.0x on the engine and shows the HUD") func hold() {
        let r = Rig()
        r.engine.state.isPaused = true
        r.press(); r.advance(0.3)
        #expect(r.engine.state.speed == 2.0)
        #expect(r.engine.state.isPaused == false)
        #expect(r.hud.shows.last?.speed == 2.0)
    }

    @Test("A3 drag right 80pt gives 2.4 and reports the px read-out") func drag() {
        let r = Rig()
        r.press(); r.advance(0.3)
        r.mouseX = 580; r.advance(0.05)
        #expect(r.engine.state.speed == 2.4)
        #expect(r.hud.shows.last?.dx == 80)
    }

    @Test("A4 release restores speed, hides HUD, stops timer, flashes the restored speed") func release() {
        let r = Rig()
        r.engine.state.speed = 1.5
        r.press(); r.advance(0.3); r.mouseX = 700; r.advance(0.05)
        r.release()
        #expect(r.engine.state.speed == 1.5)
        #expect(r.hud.hideCount == 1)
        #expect(!r.scheduler.isRunning)
        #expect(r.hud.flashes == [1.5])
        #expect(r.engine.togglePauseCount == 0)
    }

    @Test("A5 tap toggles pause, leaves speed alone, no flash") func tap() {
        let r = Rig()
        r.press(); r.advance(0.1); r.release()
        #expect(r.engine.togglePauseCount == 1)
        #expect(r.engine.setSpeedCalls.isEmpty)
        #expect(r.hud.flashes.isEmpty)
        #expect(!r.scheduler.isRunning)
    }

    @Test("A10 cancel before threshold is not a tap and stops the timer") func cancelEarly() {
        let r = Rig()
        r.press(); r.advance(0.1)
        r.controller.cancel()
        #expect(r.engine.togglePauseCount == 0)
        #expect(!r.scheduler.isRunning)
        r.release()
        #expect(r.engine.togglePauseCount == 0, "a late up after cancel is ignored")
    }

    @Test("A11 cancel during hold restores speed and hides the HUD") func cancelDuringHold() {
        let r = Rig()
        r.engine.state.speed = 1.25
        r.press(); r.advance(0.3); r.mouseX = 900; r.advance(0.05)
        r.controller.cancel()
        #expect(r.engine.state.speed == 1.25)
        #expect(r.hud.hideCount == 1)
        #expect(!r.controller.isHolding)
    }

    @Test("A13 mouse position unknown at hold start: first sample becomes the origin") func lateMouse() {
        let r = Rig()
        r.mouseX = nil
        r.press(); r.advance(0.3)
        #expect(r.engine.state.speed == 2.0)
        r.mouseX = 800; r.advance(0.05)
        #expect(r.engine.state.speed == 2.0)
        r.mouseX = 880; r.advance(0.05)
        #expect(r.engine.state.speed == 2.4)
    }

    @Test("A14 two presses without release keep a single timer") func doublePress() {
        let r = Rig()
        r.press(); r.press()
        #expect(r.scheduler.startCount == 2, "scheduler restarted, not stacked")
        #expect(r.scheduler.isRunning)
        r.advance(0.3)
        #expect(r.engine.setSpeedCalls == [2.0], "second down did not reset the hold")
    }

    @Test("A15 isActive is true from press until release or cancel, including before the hold") func isActive() {
        let r = Rig()
        #expect(!r.controller.isActive)
        r.press()
        #expect(r.controller.isActive, "pre-threshold press counts as active")
        r.advance(0.3)
        #expect(r.controller.isActive)
        r.release()
        #expect(!r.controller.isActive)
        r.press(); r.controller.cancel()
        #expect(!r.controller.isActive)
    }

    @Test("A16 a picture tap toggles immediately on release, with no timer or later toggle")
    func immediateTap() {
        let r = Rig()
        r.doubleClickInterval = 0.5
        r.press(); r.advance(0.1); r.release()
        #expect(r.engine.togglePauseCount == 1 && !r.scheduler.isRunning)
        #expect(r.engine.state.isPaused)
        #expect(!r.controller.isActive)
        r.advance(0.49)
        #expect(r.engine.togglePauseCount == 1)
        r.advance(0.02)
        #expect(r.engine.togglePauseCount == 1 && !r.scheduler.isRunning)
        r.advance(1)
        #expect(r.engine.togglePauseCount == 1)
        r.press(); r.advance(0.1); r.release()
        r.controller.cancel(); r.advance(1)
        #expect(r.engine.togglePauseCount == 2 && !r.scheduler.isRunning)
        #expect(!r.engine.state.isPaused)
    }

    @Test("A17 a hold starts normally and never schedules a pause after releasing it")
    func immediateTapStillHolds() {
        let r = Rig()
        r.doubleClickInterval = 0.5
        r.engine.state.speed = 1.5
        r.press(); r.advance(0.3)
        #expect(r.controller.isHolding && r.engine.state.speed == 2)
        r.release(); r.advance(1)
        #expect(r.engine.state.speed == 1.5)
        #expect(r.engine.togglePauseCount == 0 && !r.scheduler.isRunning)
    }

    @Test("A18 separate clicks each toggle on release without waiting for another press")
    func separateClicks() {
        let r = Rig()
        r.doubleClickInterval = 0.5
        r.press(); r.advance(0.1); r.release()
        #expect(r.engine.togglePauseCount == 1)
        r.advance(0.1); r.press()
        #expect(r.engine.togglePauseCount == 1)
        r.advance(0.1); r.release()
        #expect(r.engine.togglePauseCount == 2 && !r.scheduler.isRunning)
    }

    @Test("A19 double-click undoes exactly one completed tap", arguments: [false, true])
    func doubleClickRestores(initiallyPaused: Bool) {
        let r = Rig()
        r.engine.state.isPaused = initiallyPaused
        r.press(); r.advance(0.05); r.release()
        #expect(r.engine.state.isPaused != initiallyPaused)
        r.controller.doubleClick()
        #expect(r.engine.state.isPaused == initiallyPaused)
        #expect(r.engine.togglePauseCount == 2)
        #expect(r.engine.setPausedCalls.isEmpty)
        r.release(); r.controller.doubleClick(); r.advance(1)
        #expect(r.engine.togglePauseCount == 2 && !r.scheduler.isRunning)
    }

    @Test("A20 a double-click without a tap, after expiry, or after cancel never undoes playback")
    func doubleClickWithoutEligibleTap() {
        let r = Rig()
        r.controller.doubleClick()
        #expect(r.engine.togglePauseCount == 0)
        r.press(); r.release(); r.advance(0.51)
        r.controller.doubleClick()
        #expect(r.engine.togglePauseCount == 1 && r.engine.state.isPaused)
        r.press(); r.release(); r.controller.cancel()
        r.controller.doubleClick()
        #expect(r.engine.togglePauseCount == 2 && !r.engine.state.isPaused)
    }

    @Test("A21 a later press and hold cannot undo an earlier completed tap")
    func holdDiscardsTapUndo() {
        let r = Rig()
        r.press(); r.release()
        r.press(); r.advance(0.3)
        #expect(r.controller.isHolding && r.engine.state.speed == 2)
        r.controller.doubleClick(); r.release()
        #expect(r.engine.state.speed == 1 && !r.controller.isActive)
        #expect(r.engine.togglePauseCount == 1 && !r.scheduler.isRunning)
        #expect(!r.engine.state.isPaused, "the hold still resumes paused playback")
    }

    @Test("A22 queued double-clicks use occurrence times even when both clicks are delivered late", arguments: [false, true])
    func queuedDoubleClick(initiallyPaused: Bool) {
        let r = Rig()
        r.engine.state.isPaused = initiallyPaused
        r.now = 100
        r.controller.mouseDown(eventTime: 10)
        r.advance(0.05); r.release()
        #expect(r.engine.state.isPaused != initiallyPaused)
        r.now = 200
        r.controller.doubleClick(eventTime: 10.1)
        #expect(r.engine.state.isPaused == initiallyPaused)
        #expect(r.engine.togglePauseCount == 2 && !r.scheduler.isRunning)
        r.release(); r.advance(1)
        #expect(r.engine.togglePauseCount == 2)
    }

    @Test("A23 timestamps outside the first-down double-click interval never undo a tap", arguments: [-0.01, 0.501])
    func unrelatedEventTime(interval: Double) {
        let r = Rig()
        r.now = 100
        r.controller.mouseDown(eventTime: 10)
        r.advance(0.1); r.release()
        r.controller.doubleClick(eventTime: 10 + interval)
        #expect(r.engine.togglePauseCount == 1 && r.engine.state.isPaused)
        #expect(!r.controller.isActive && !r.scheduler.isRunning)
    }
}
