import Foundation

/// How each video was left: audio track, subtitles ("no" = off, or an embedded
/// track id) and subtitle timing. Reopening the video restores them (2026-10-19).
final class PlaybackMemory {
    struct Entry: Codable, Equatable {
        var audioTrack: String?
        var subtitleTrack: String?
        var subtitleDelay: Double?
        var usedAt: Double = 0

        init(audioTrack: String? = nil, subtitleTrack: String? = nil, subtitleDelay: Double? = nil) {
            self.audioTrack = audioTrack
            self.subtitleTrack = subtitleTrack
            self.subtitleDelay = subtitleDelay
        }

        static func == (a: Entry, b: Entry) -> Bool {
            a.audioTrack == b.audioTrack && a.subtitleTrack == b.subtitleTrack && a.subtitleDelay == b.subtitleDelay
        }
    }

    static let key = "videotool.playback-memory"
    private let defaults: UserDefaults
    private let maxEntries: Int

    init(defaults: UserDefaults = AppData.defaults, maxEntries: Int = 1000) {
        self.defaults = defaults
        self.maxEntries = maxEntries
    }

    func entry(for path: String) -> Entry? { table()[path] }

    func update(_ path: String, _ change: (inout Entry) -> Void) {
        var t = table()
        var e = t[path] ?? Entry()
        change(&e)
        e.usedAt = Date().timeIntervalSince1970 + Double(t.count) * 1e-6     // keeps order within one second
        t[path] = e
        if t.count > maxEntries {
            for (p, _) in t.sorted(by: { $0.value.usedAt < $1.value.usedAt }).prefix(t.count - maxEntries) { t.removeValue(forKey: p) }
        }
        defaults.set(try? JSONEncoder().encode(t), forKey: Self.key)
    }

    func forget(_ path: String) {
        var t = table()
        t.removeValue(forKey: path)
        defaults.set(try? JSONEncoder().encode(t), forKey: Self.key)
    }

    private func table() -> [String: Entry] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
}
