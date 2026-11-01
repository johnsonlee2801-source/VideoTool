import Foundation

struct NetworkWatchEntry: Equatable {
    let video: NetworkVideo
    let title: String
    var position: Double
    var duration: Double
    var watchedAt: Date
    var finished: Bool
    var watch: WatchEntry { WatchEntry(position: position, duration: duration, watchedAt: watchedAt, finished: finished) }
}

/// Separate from local indexing/history. Only canonical public page identities
/// are persisted; stream URLs, headers and share parameters never enter the store.
final class NetworkWatchHistoryStore {
    static let didChange = Notification.Name("VideoTool.NetworkWatchHistory.didChange")
    static let defaultKey = "videotool.network-watch-history"
    let defaults: UserDefaults
    private let maxEntries: Int
    private let now: () -> Date
    init(defaults: UserDefaults = AppData.defaults, maxEntries: Int = 100, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.maxEntries = max(1, maxEntries); self.now = now
    }
    var entries: [NetworkWatchEntry] {
        table().compactMap { key, row -> NetworkWatchEntry? in
            guard let raw = row["url"] as? String, let video = try? NetworkVideo(raw),
                  video.site == .youtube || (video.site == .bilibili && video.id.hasPrefix("BV")),
                  video.url.absoluteString == raw, video.key == key,
                  let title = row["title"] as? String,
                  let p = row["position"] as? Double, p.isFinite, p >= 0,
                  let d = row["duration"] as? Double, d.isFinite, d >= 0,
                  let t = row["time"] as? Double, t.isFinite else { return nil }
            return NetworkWatchEntry(video: video, title: title, position: p, duration: d,
                                     watchedAt: Date(timeIntervalSince1970: t), finished: row["finished"] as? Bool ?? false)
        }.sorted { $0.watchedAt == $1.watchedAt ? $0.video.key < $1.video.key : $0.watchedAt > $1.watchedAt }
    }
    func record(_ video: NetworkVideo, title: String, position: Double, duration: Double, finished: Bool = false) {
        guard video.site == .youtube || (video.site == .bilibili && video.id.hasPrefix("BV")),
              position.isFinite, position >= 0, duration.isFinite, duration >= 0 else { return }
        var rows = table()
        let cleanTitle = String(String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(300))
        rows[video.key] = ["url": video.url.absoluteString, "title": cleanTitle, "position": position,
                           "duration": duration, "time": now().timeIntervalSince1970, "finished": finished]
        if rows.count > maxEntries {
            let oldest = rows.filter { $0.key != video.key }.sorted { ($0.value["time"] as? Double ?? 0) < ($1.value["time"] as? Double ?? 0) }
            for row in oldest.prefix(rows.count - maxEntries) { rows.removeValue(forKey: row.key) }
        }
        write(rows)
    }
    func remove(_ key: String) { var rows = table(); rows.removeValue(forKey: key); write(rows) }
    func clear() { write([:]) }
    private func table() -> [String: [String: Any]] { defaults.dictionary(forKey: Self.defaultKey) as? [String: [String: Any]] ?? [:] }
    private func write(_ rows: [String: [String: Any]]) {
        defaults.set(rows, forKey: Self.defaultKey)
        NotificationCenter.default.post(name: Self.didChange, object: defaults)
    }
}

struct ContinueWatchingItem: Equatable {
    let url: URL
    let title: String
    let position: Double
    let watchedAt: Date
    static func latest(local: [String: WatchEntry], network: [NetworkWatchEntry]) -> Self? {
        func resumable(_ entry: WatchEntry) -> Bool {
            !entry.isWatched && ResumePositionStore.resumeTarget(position: entry.position, duration: entry.duration) != nil
        }
        let files = local.compactMap { path, watch -> Self? in
            guard resumable(watch) else { return nil }
            return Self(url: URL(fileURLWithPath: path), title: (path as NSString).lastPathComponent,
                        position: watch.position, watchedAt: watch.watchedAt)
        }
        let links = network.filter { resumable($0.watch) }.map {
            Self(url: $0.video.url, title: $0.title, position: $0.position, watchedAt: $0.watchedAt)
        }
        return (files + links).sorted {
            $0.watchedAt == $1.watchedAt ? $0.url.absoluteString < $1.url.absoluteString : $0.watchedAt > $1.watchedAt
        }.first
    }
}
