import Foundation

/// A fixed six-second detail window; it stays fixed during a drag.
struct ClipZoomWindow: Equatable {
    let lower: Double
    let upper: Double
    init(center: Double, duration: Double) {
        let duration = duration.isFinite ? max(0, duration) : 0
        let center = center.isFinite ? min(duration, max(0, center)) : 0
        lower = max(0, min(center - 3, max(0, duration - 6)))
        upper = min(duration, lower + 6)
    }
    func time(fraction: Double) -> Double { lower + (upper - lower) * max(0, min(1, fraction.isFinite ? fraction : 0)) }
}

enum ClipAdjustment {
    /// Nominal frame duration, not a claim of frame-accurate VFR indexing.
    static func step(fps: Double?) -> Double {
        guard let fps, fps.isFinite, (0.1...1000).contains(fps) else { return 0.01 }
        return 1 / fps
    }
    static func text(_ time: Double) -> String {
        let value = min(SRT.maxSeconds, max(0, time.isFinite ? time : 0))
        let ms = Int((value * 1000).rounded())
        return TimeFormatting.string(Double(ms / 1000)) + String(format: ".%03d", ms % 1000)
    }
}
