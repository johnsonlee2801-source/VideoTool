import AppKit
import Testing
@testable import VideoTool

// Decision recorded 2026-10-18: while the speed gesture is active (button down,
// before or during the hold), a plain key only cancels the gesture and is
// swallowed. Chords (⌘/⌃/⌥) still cancel and then reach the menu bar.

@Suite struct KeyRouterTests {
    private func key(_ k: String, command: Bool = false) -> KeyInput { KeyInput(key: k, command: command) }

    @Test("K1 idle: mapped keys perform their command") func idleCommand() {
        #expect(KeyRouter.decide(key(KeyInput.space), gestureActive: false) == .perform(.togglePause))
        #expect(KeyRouter.decide(key("]"), gestureActive: false) == .perform(.speedDelta(0.1)))
    }
    @Test("K2 idle: unmapped keys and chords pass through") func idlePassThrough() {
        #expect(KeyRouter.decide(key("z"), gestureActive: false) == .passThrough)
        #expect(KeyRouter.decide(key("o", command: true), gestureActive: false) == .passThrough)
        #expect(KeyRouter.decide(nil, gestureActive: false) == .passThrough)
    }
    @Test("K3 gesture active: a plain key cancels and is swallowed (space does not also pause)") func activePlain() {
        #expect(KeyRouter.decide(key(KeyInput.space), gestureActive: true) == .cancelGestureOnly)
        #expect(KeyRouter.decide(key("z"), gestureActive: true) == .cancelGestureOnly)
    }
    @Test("K3b with cancelsOnly=false a plain key performs its command (the caller has already cancelled)")
    func activePlainCommandMode() {
        #expect(KeyRouter.decide(key(KeyInput.space), gestureActive: true, plainKeyCancelsOnly: false) == .perform(.togglePause))
        #expect(KeyRouter.decide(key("z"), gestureActive: true, plainKeyCancelsOnly: false) == .passThrough)
    }
    @Test("K4 gesture active: chords cancel and still reach the menu bar") func activeChord() {
        #expect(KeyRouter.decide(key("q", command: true), gestureActive: true) == .cancelGestureAndPassThrough)
        #expect(KeyRouter.decide(nil, gestureActive: true) == .cancelGestureAndPassThrough)
    }

    private func event(_ keyCode: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)!
    }
    @Test("K5 NSEvent → KeyInput: arrows, space, delete, letters, modifiers") func fromEvent() {
        #expect(KeyRouter.input(from: event(123, "\u{F702}")) == KeyInput(key: KeyInput.left))
        #expect(KeyRouter.input(from: event(124, "\u{F703}", .shift)) == KeyInput(key: KeyInput.right, shift: true))
        #expect(KeyRouter.input(from: event(49, " ")) == KeyInput(key: KeyInput.space))
        #expect(KeyRouter.input(from: event(51, "\u{7F}")) == KeyInput(key: KeyInput.delete))
        #expect(KeyRouter.input(from: event(3, "F")) == KeyInput(key: "f"))
        #expect(KeyRouter.input(from: event(12, "q", .command)) == KeyInput(key: "q", command: true))
    }
}
