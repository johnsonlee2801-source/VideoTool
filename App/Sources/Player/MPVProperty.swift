import Libmpv

/// The mpv properties the player observes. The raw value is the reply id mpv
/// hands back with each change (0 is reserved: it means "no id").
enum MPVProperty: UInt64, CaseIterable {
    case timePos = 1, duration, pause, speed, volume, mute, mediaTitle, eofReached, idleActive, path

    var name: String {
        switch self {
        case .timePos: return "time-pos"
        case .duration: return "duration"
        case .pause: return "pause"
        case .speed: return "speed"
        case .volume: return "volume"
        case .mute: return "mute"
        case .mediaTitle: return "media-title"
        case .eofReached: return "eof-reached"
        case .idleActive: return "idle-active"
        case .path: return "path"
        }
    }

    var format: mpv_format {
        switch self {
        case .timePos, .duration, .speed, .volume: return MPV_FORMAT_DOUBLE
        case .pause, .mute, .eofReached, .idleActive: return MPV_FORMAT_FLAG
        case .mediaTitle, .path: return MPV_FORMAT_STRING
        }
    }
}

/// A property value copied out of mpv's event memory (valid only during the event).
enum MPVValue: Equatable {
    case double(Double)
    case flag(Bool)
    case string(String?)
    /// The property has no value right now (e.g. duration after playback stops).
    case unavailable

    /// nil for formats the player never asks for, or a number/flag with no data.
    init?(_ p: mpv_event_property) {
        switch p.format {
        case MPV_FORMAT_DOUBLE:
            guard let d = p.data else { return nil }
            self = .double(d.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_FLAG:
            guard let d = p.data else { return nil }
            self = .flag(d.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_STRING:
            let c = p.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
            self = .string(c.map { String(cString: $0) })
        case MPV_FORMAT_NONE:
            self = .unavailable
        default:
            return nil
        }
    }
}

extension PlayerState {
    /// Applies one property change; false if it does not affect the state.
    mutating func apply(_ prop: MPVProperty, _ value: MPVValue) -> Bool {
        switch (prop, value) {
        case (.timePos, .double(let v)): timePos = v
        case (.duration, .double(let v)): duration = v
        case (.speed, .double(let v)): speed = v
        case (.volume, .double(let v)): volume = v
        case (.pause, .flag(let v)): isPaused = v
        case (.mute, .flag(let v)): isMuted = v
        case (.eofReached, .flag(let v)): eofReached = v
        case (.idleActive, .flag(let v)): isIdle = v
        case (.mediaTitle, .string(let v?)): mediaTitle = v
        case (.path, .string(let v)): path = v
        // Unavailable: position, length and file go back to "nothing loaded".
        // Settings (speed, volume, pause, mute) keep their last value.
        case (.timePos, .unavailable): timePos = 0
        case (.duration, .unavailable): duration = 0
        case (.path, .unavailable): path = nil
        case (.mediaTitle, .unavailable): mediaTitle = ""
        case (.eofReached, .unavailable): eofReached = false   // defensive: mpv normally sends an explicit false
        case (.idleActive, .unavailable): isIdle = true
        default: return false
        }
        return true
    }
}
