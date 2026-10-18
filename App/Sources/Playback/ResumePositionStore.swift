import Foundation

/// Remembers where each file was left, keyed by path. Small, UserDefaults-backed.
final class ResumePositionStore {
    static let defaultKey = "videotool.resume-positions"
    static let minimumPosition = 5.0      // shorter than this: start over
    static let tailMargin = 10.0           // this close to the end: start over
    static let maxEntries = 500

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, key: String = ResumePositionStore.defaultKey, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.now = now
    }

    func position(for url: URL) -> Double? {
        (table()[url.path]?["position"]).flatMap { $0 }
    }

    func save(_ position: Double, for url: URL) {
        guard position.isFinite, position >= 0 else { return }
        var t = table()
        t[url.path] = ["position": position, "savedAt": now().timeIntervalSince1970]
        if t.count > Self.maxEntries {
            let sorted = t.sorted { ($0.value["savedAt"] ?? 0) < ($1.value["savedAt"] ?? 0) }
            for (path, _) in sorted.prefix(t.count - Self.maxEntries) { t.removeValue(forKey: path) }
        }
        defaults.set(t, forKey: key)
    }

    func clear(for url: URL) {
        var t = table()
        t.removeValue(forKey: url.path)
        defaults.set(t, forKey: key)
    }

    var count: Int { table().count }

    /// Decides whether a stored position is worth resuming from.
    static func resumeTarget(position: Double?, duration: Double) -> Double? {
        guard let position, position.isFinite, position >= minimumPosition else { return nil }
        if duration > 0 && position > duration - tailMargin { return nil }
        return position
    }

    private func table() -> [String: [String: Double]] {
        defaults.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
    }
}
