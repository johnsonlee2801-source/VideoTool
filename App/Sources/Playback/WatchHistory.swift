import Foundation

/// How far a file has been watched (for "继续观看" and progress bars on covers).
struct WatchEntry: Equatable {
    var position: Double
    var duration: Double
    var watchedAt: Date
    var finished: Bool

    var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }

    /// Played to the end, or stopped in the last 10 s / 3 % (end credits).
    var isWatched: Bool {
        finished || (duration > 0 && (position >= duration - ResumePositionStore.tailMargin || fraction >= 0.97))
    }
}

/// Watch progress per file path. Written by the player every few seconds, read by
/// the library. Separate from resume positions, which are cleared at the end.
final class WatchHistoryStore {
    static let defaultKey = "videotool.watch-history"
    private let defaults: UserDefaults
    private let key: String
    private let maxEntries: Int
    private let now: () -> Date

    init(defaults: UserDefaults = AppData.defaults, key: String = WatchHistoryStore.defaultKey,
         maxEntries: Int = 2000, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.maxEntries = maxEntries
        self.now = now
    }

    func entry(for path: String) -> WatchEntry? { table()[path].flatMap(Self.decode) }

    var all: [String: WatchEntry] { table().compactMapValues(Self.decode) }

    func recordProgress(path: String, position: Double, duration: Double) {
        guard position.isFinite, position >= 0 else { return }
        write(path, WatchEntry(position: position, duration: max(duration, 0), watchedAt: now(), finished: false))
    }

    func markFinished(path: String, duration: Double) {
        let d = max(duration, entry(for: path)?.duration ?? 0)
        write(path, WatchEntry(position: d, duration: d, watchedAt: now(), finished: true))
    }

    // MARK: private

    private func write(_ path: String, _ e: WatchEntry) {
        var t = table()
        t[path] = ["p": e.position, "d": e.duration, "t": e.watchedAt.timeIntervalSince1970, "f": e.finished ? 1 : 0]
        if t.count > maxEntries {
            let oldest = t.sorted { ($0.value["t"] ?? 0) < ($1.value["t"] ?? 0) }.prefix(t.count - maxEntries)
            for (p, _) in oldest { t.removeValue(forKey: p) }
        }
        defaults.set(t, forKey: key)
    }

    private func table() -> [String: [String: Double]] {
        defaults.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
    }

    private static func decode(_ v: [String: Double]) -> WatchEntry? {
        guard let p = v["p"], let d = v["d"], let t = v["t"] else { return nil }
        return WatchEntry(position: p, duration: d, watchedAt: Date(timeIntervalSince1970: t), finished: (v["f"] ?? 0) != 0)
    }
}
