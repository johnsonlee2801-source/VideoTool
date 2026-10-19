import Foundation

enum PlayerCommand: Equatable {
    case togglePause
    case seek(Double)          // relative seconds
    case volume(Double)        // relative percent
    case toggleMute
    case toggleFullscreen
    case cycleSubtitle
    case cycleAudio
    case speedDelta(Double)
    case resetSpeed
    case setSpeed(Double)      // a fixed speed from the speed menu
    case subtitleDelay(Double) // relative seconds (Z earlier, X later)
    case toggleBookmark
    case previousBookmark
    case nextBookmark
}

/// Normalised key press: lowercase character or a named special key.
struct KeyInput: Equatable {
    var key: String
    var shift = false
    var command = false
    var option = false
    var control = false

    static let left = "left", right = "right", up = "up", down = "down"
    static let space = "space", delete = "delete", escape = "escape"
}

/// Pure keyboard map. Command-modified keys belong to the menu bar and are
/// never handled here.
enum KeyCommandMap {
    static func command(for input: KeyInput) -> PlayerCommand? {
        // ⌥← / ⌥→: previous / next star. The only Option chords the player handles.
        if input.option && !input.command && !input.control && !input.shift {
            switch input.key {
            case KeyInput.left: return .previousBookmark
            case KeyInput.right: return .nextBookmark
            default: return nil
            }
        }
        if input.command || input.control || input.option { return nil }
        switch input.key {
        case KeyInput.space: return .togglePause
        case KeyInput.left:  return .seek(input.shift ? -30 : -5)
        case KeyInput.right: return .seek(input.shift ? 30 : 5)
        case KeyInput.up:    return .volume(5)
        case KeyInput.down:  return .volume(-5)
        case KeyInput.delete: return .resetSpeed
        case "f": return .toggleFullscreen
        case "m": return .toggleMute
        case "s": return .cycleSubtitle
        case "a": return .cycleAudio
        case "z": return .subtitleDelay(-0.1)
        case "x": return .subtitleDelay(0.1)
        case "[": return .speedDelta(-0.1)
        case "]": return .speedDelta(0.1)
        case "b": return .toggleBookmark
        default: return nil
        }
    }
}
