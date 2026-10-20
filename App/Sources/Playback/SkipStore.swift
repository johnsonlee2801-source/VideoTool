import Foundation

/// Where a series' intro ends and its outro starts (set once while watching any
/// episode; every episode of that show and season then skips them). A video that is
/// not an episode of a series has a setting of its own (see `key(for:)`).
final class SkipStore {
    struct Skips: Codable, Equatable {
        var introEnd: Double?
        var outroStart: Double?
    }

    static let key = "videotool.skips"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = AppData.defaults) { self.defaults = defaults }

    /// "series:<show>|s<season>", or "file:<path>" for a video without an episode number.
    /// A weak match ("Holiday 01") counts as a series only with another episode of it in
    /// the same folder; S01E02-style names need no such evidence (audit 2026-10-20).
    /// (not its folder: an intro marked on one download must not cut the start off every
    /// other video in ~/Downloads; audit 2026-10-20).
    static func key(for path: String) -> String {
        if let e = EpisodeParser.parse((path as NSString).lastPathComponent), e.strong || hasSibling(of: e, at: path) {
            return "series:\(EpisodeParser.normalizedTitle(e.title))|s\(e.season ?? 0)"
        }
        return "file:" + path
    }

    private static func hasSibling(of e: EpisodeInfo, at path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent, show = EpisodeParser.normalizedTitle(e.title)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.contains { name in
            guard let o = EpisodeParser.parse(name) else { return false }
            return EpisodeParser.normalizedTitle(o.title) == show && o.season == e.season && o.episode != e.episode
        }
    }

    func skips(for key: String) -> Skips? { table()[key] }

    func update(_ key: String, _ change: (inout Skips) -> Void) {
        var t = table()
        var s = t[key] ?? Skips()
        change(&s)
        t[key] = s
        defaults.set(try? JSONEncoder().encode(t), forKey: Self.key)
    }

    func clear(_ key: String) {
        var t = table()
        t.removeValue(forKey: key)
        defaults.set(try? JSONEncoder().encode(t), forKey: Self.key)
    }

    private func table() -> [String: Skips] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Skips].self, from: $0) } ?? [:]
    }
}

enum SeriesNavigator {
    /// The following episode of the same show and season in the same folder (the
    /// smallest higher number), or nil.
    static func nextEpisode(after path: String) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        guard let me = EpisodeParser.parse((path as NSString).lastPathComponent),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let show = EpisodeParser.normalizedTitle(me.title)
        return names.compactMap { name -> (Int, String)? in
            let full = (dir as NSString).appendingPathComponent(name)
            guard MediaTypes.isMedia(URL(fileURLWithPath: full)), let e = EpisodeParser.parse(name),
                  EpisodeParser.normalizedTitle(e.title) == show, e.season == me.season, e.episode > me.episode else { return nil }
            return (e.episode, full)
        }.min { $0.0 < $1.0 }?.1
    }
}

/// Night mode: the deep rumble of explosions and music cut, the voice band lifted.
/// An equaliser, not a compressor: MPVKit's FFmpeg ships no dynamics filters.
enum NightMode {
    static let key = "videotool.night-mode"
    static let filter = "@night:lavfi=[equalizer=f=60:t=o:w=2:g=-14,equalizer=f=2000:t=o:w=2:g=5]"
    static var isOn: Bool {
        get { AppData.defaults.bool(forKey: key) }
        set { AppData.defaults.set(newValue, forKey: key) }
    }
}
