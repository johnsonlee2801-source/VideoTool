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
        #expect(KeyRouter.decide(key("q"), gestureActive: false) == .passThrough)
        #expect(KeyRouter.decide(key("o", command: true), gestureActive: false) == .passThrough)
        #expect(KeyRouter.decide(nil, gestureActive: false) == .passThrough)
    }
    @Test("K3 gesture active: a plain key cancels and is swallowed (space does not also pause)") func activePlain() {
        #expect(KeyRouter.decide(key(KeyInput.space), gestureActive: true) == .cancelGestureOnly)
        #expect(KeyRouter.decide(key("q"), gestureActive: true) == .cancelGestureOnly)
    }
    @Test("K3b with cancelsOnly=false a plain key performs its command (the caller has already cancelled)")
    func activePlainCommandMode() {
        #expect(KeyRouter.decide(key(KeyInput.space), gestureActive: true, plainKeyCancelsOnly: false) == .perform(.togglePause))
        #expect(KeyRouter.decide(key("q"), gestureActive: true, plainKeyCancelsOnly: false) == .passThrough)
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

    @Test("K6 decision 2026-10-18: B while the speed gesture is active only cancels; it does not star")
    func bDuringGesture() {
        #expect(KeyRouter.decide(key("b"), gestureActive: true) == .cancelGestureOnly)
        #expect(KeyRouter.decide(key("b"), gestureActive: false) == .perform(.toggleBookmark))
    }
    @Test("K7 idle ⌥→ performs next-star (option chords for stars are not passed to the menu bar)")
    func optionArrowsIdle() {
        #expect(KeyRouter.decide(KeyInput(key: KeyInput.right, option: true), gestureActive: false) == .perform(.nextBookmark))
    }

    @Test("K8 while typing in a text field (e.g. a star note) every key goes to the field")
    func editingText() {
        #expect(KeyRouter.decide(key("b"), gestureActive: false, isEditingText: true) == .passThrough)
        #expect(KeyRouter.decide(key(KeyInput.space), gestureActive: false, isEditingText: true) == .passThrough)
        #expect(KeyRouter.decide(KeyInput(key: KeyInput.left, option: true), gestureActive: false, isEditingText: true) == .passThrough)
    }
}

// Audit 2026-10-20 (clip feature): holding a key sends repeats.
struct KeyRepeatTests {
    @Test("KR20 a held key acts once for toggles (C, B, Space, F, M, S, A, ⌫) but keeps going for steps (arrows, volume, speed, Z/X)")
    func repeats() {
        for key in ["c", "b", KeyInput.space, "f", "m", "s", "a", KeyInput.delete] {
            #expect(KeyRouter.decide(KeyInput(key: key, isRepeat: true), gestureActive: false) == .swallow, "\(key)")
            #expect(KeyRouter.decide(KeyInput(key: key), gestureActive: false) != .swallow, "\(key) first press acts")
        }
        for key in [KeyInput.left, KeyInput.right, KeyInput.up, KeyInput.down, "[", "]", "z", "x"] {
            guard case .perform = KeyRouter.decide(KeyInput(key: key, isRepeat: true), gestureActive: false) else {
                Issue.record("\(key) should repeat"); continue
            }
        }
    }

    @Test("KR21 the repeat flag is read from the key event")
    func fromEvent() throws {
        let held = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: true, keyCode: 8))
        #expect(KeyRouter.input(from: held)?.isRepeat == true)
    }
}
