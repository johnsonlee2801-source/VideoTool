import Foundation

struct PlayerState: Equatable {
    var isPaused = true
    var speed = 1.0
    var timePos = 0.0
    var duration = 0.0
    var volume = 100.0
    var isMuted = false
    var mediaTitle = ""
    var path: String?
    var isIdle = true
    var eofReached = false
}

enum PlayerEvent: Equatable {
    /// Path and duration are read from mpv at FILE_LOADED time, so consumers
    /// never depend on the order of property-change notifications.
    case fileLoaded(path: String, duration: Double)
    case endFile(eof: Bool)
    case log(String)
}

/// What the UI and the gesture code need from a player. `MPVEngine` is the
/// real one; tests use a fake.
protocol PlayerEngine: AnyObject {
    var state: PlayerState { get }
    var onStateChange: ((PlayerState) -> Void)? { get set }
    var onEvent: ((PlayerEvent) -> Void)? { get set }

    func load(_ url: URL)
    func stop()
    func setPaused(_ paused: Bool)
    func togglePause()
    func seek(to seconds: Double)
    func seek(by delta: Double)
    func scrub(to seconds: Double)
    func setSpeed(_ speed: Double)
    func setVolume(_ volume: Double)
    func toggleMute()
    func cycleSubtitle()
    func cycleAudio()
}
