import Foundation

/// Pure rules for starred moments. User decisions 2026-10-18: jumping to a
/// star lands `preRoll` seconds before it; pressing B again right after
/// starring (same spot, within a few seconds) undoes the star.
enum BookmarkNavigator {
    static let preRoll = 2.0
    /// A star this close to the playhead counts as "here", not as next.
    static let epsilon = 0.01
    /// Played this far past a star, ⌥← returns to it rather than to the one before.
    static let previousGrace = 0.5
    static let undoDistance = 1.0
    static let undoWindow = 3.0

    static func jumpTarget(_ starTime: Double) -> Double { max(0, starTime - preRoll) }

    /// Next star after the playhead. Star *times* are compared, not landing points,
    /// so stars in the first 2 s and stars closer than 2 s apart are reachable.
    /// `landedOn` is the star the last ⌥←/⌥→ jumped to: after landing (2 s
    /// before it) that star is "current", so next means the one after it.
    static func next(after current: Double, in stars: [Double], landedOn: Double? = nil) -> Double? {
        let reference = landedOn ?? current
        return stars.sorted().first { $0 > reference + epsilon }
    }

    static func previous(before current: Double, in stars: [Double], landedOn: Double? = nil) -> Double? {
        if let landedOn { return stars.sorted().last { $0 < landedOn - epsilon } }
        return stars.sorted().last { $0 < current - previousGrace }
    }

    /// Nearest star within `tolerance` seconds of a click; ties go to the earlier star.
    static func snap(_ click: Double, to stars: [Double], tolerance: Double) -> Double? {
        var best: Double?
        for s in stars.sorted() where abs(s - click) <= tolerance {
            if best == nil || abs(s - click) < abs(best! - click) { best = s }
        }
        return best
    }

    enum ToggleDecision: Equatable { case add, undo(UUID) }

    /// `speed` widens the undo distance: at 3× a quick double press covers 3× the video time.
    static func toggle(at time: Double, now: Date, existing: [Bookmark], speed: Double = 1) -> ToggleDecision {
        let distance = undoDistance * max(1, speed)
        let candidates = existing.filter {
            abs($0.time - time) <= distance && now.timeIntervalSince($0.createdAt) <= undoWindow
        }
        guard let newest = candidates.max(by: { $0.createdAt < $1.createdAt }) else { return .add }
        return .undo(newest.id)
    }

    /// X position of a marker on the slider track; nil when the duration is unknown.
    static func markerX(time: Double, duration: Double, trackMinX: Double, trackWidth: Double) -> Double? {
        guard duration > 0, duration.isFinite else { return nil }
        let fraction = min(max(time / duration, 0), 1)
        return trackMinX + fraction * trackWidth
    }
}
