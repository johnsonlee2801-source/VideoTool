import AppKit

enum KeyDecision: Equatable {
    case perform(PlayerCommand)
    case passThrough
    /// Gesture was active: cancel it and swallow the key.
    case cancelGestureOnly
    /// Gesture was active: cancel it, then let the key reach the menu bar.
    case cancelGestureAndPassThrough
}

/// Routes key-downs for the player window. Decision 2026-10-18: while the
/// speed gesture is active (button down, before or during the hold) a plain key
/// only cancels it, so Space does not also toggle pause. Change
/// `plainKeyCancelsOnly` to false to make the key act after cancelling.
enum KeyRouter {
    static let plainKeyCancelsOnly = true

    static func decide(_ input: KeyInput?, gestureActive: Bool, isEditingText: Bool = false,
                       plainKeyCancelsOnly: Bool = KeyRouter.plainKeyCancelsOnly) -> KeyDecision {
        // Typing a star note: the text field owns every key.
        if isEditingText { return .passThrough }
        let isChord = input.map { $0.command || $0.control || $0.option } ?? true
        if gestureActive {
            if isChord { return .cancelGestureAndPassThrough }
            if plainKeyCancelsOnly { return .cancelGestureOnly }
        }
        // Reached only when idle, or active with plainKeyCancelsOnly == false (the
        // caller has already cancelled the gesture in that case).
        guard let input, let command = KeyCommandMap.command(for: input) else { return .passThrough }
        return .perform(command)
    }

    static func input(from event: NSEvent) -> KeyInput? {
        let flags = event.modifierFlags
        var input = KeyInput(key: "",
                             shift: flags.contains(.shift),
                             command: flags.contains(.command),
                             option: flags.contains(.option),
                             control: flags.contains(.control))
        switch event.keyCode {
        case 123: input.key = KeyInput.left
        case 124: input.key = KeyInput.right
        case 126: input.key = KeyInput.up
        case 125: input.key = KeyInput.down
        case 49: input.key = KeyInput.space
        case 51: input.key = KeyInput.delete
        case 53: input.key = KeyInput.escape
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return nil }
            input.key = chars
        }
        return input
    }
}
