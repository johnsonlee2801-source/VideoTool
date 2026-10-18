import Foundation

/// What a progress-bar action should do. Only a drag is "scrubbing" (fast
/// keyframe seeks, the bar stops following playback); a click, the mouse-up or
/// a keyboard change ends scrubbing with one exact seek, snapped to a nearby star.
enum ScrubPolicy {
    enum Seek: Equatable { case keyframe(Double), exact(Double) }

    struct Decision: Equatable {
        var isScrubbing: Bool
        var seek: Seek
    }

    /// `snapRadius` is in points; `trackWidth` is the slider's usable width.
    static func decide(isDrag: Bool, value: Double, duration: Double, trackWidth: Double,
                       snapRadius: Double, snap: (Double, Double) -> Double) -> Decision {
        let v = min(max(value, 0), max(duration, 0))
        if isDrag { return Decision(isScrubbing: true, seek: .keyframe(v)) }
        let tolerance = trackWidth > 0 ? snapRadius * duration / trackWidth : 0
        return Decision(isScrubbing: false, seek: .exact(snap(v, tolerance)))
    }
}
