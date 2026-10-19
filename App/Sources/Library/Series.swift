import Foundation

/// What a file name says about the episode it holds.
struct EpisodeInfo: Equatable {
    var title: String
    var season: Int?
    var episode: Int
    /// An explicit marker (S01E02, 1x02, EP02, 第2集). Weak matches ("Show - 07",
    /// "Show 07") only count when another episode of the same show is present.
    var strong: Bool
}

/// Reads show, season and episode from file names as people actually name them:
/// "Show.S02E05.1080p", "Show 3x14", "[Group] Show - 07 [1080p]", "剧名 第二季 第3集",
/// "课程 EP03". Release tags, years and resolutions are not taken for episodes.
enum EpisodeParser {
    static func parse(_ fileName: String) -> EpisodeInfo? {
        var name = (fileName as NSString).deletingPathExtension
        // Leading release-group tags: "[Sakura] ", "【字幕组】".
        while let r = name.range(of: #"^\s*[\[【][^\]】]*[\]】]\s*"#, options: .regularExpression) { name.removeSubrange(r) }
        let season = chineseSeason(in: name)

        let strong: [(String, (NSTextCheckingResult, NSString) -> (season: Int?, episode: Int)?)] = [
            (#"(?i)\bS(\d{1,2})[ ._-]?E(\d{1,4})(?:-?E\d{1,4})*\b"#, { m, s in (int(m, 1, s), int(m, 2, s)!) }),
            (#"(?<![\d])(\d{1,2})x(\d{2,3})(?![\d])"#, { m, s in (int(m, 1, s), int(m, 2, s)!) }),
            (#"第\s*([0-9]{1,4}|[零〇一二两三四五六七八九十百]+)\s*[集话話回期]"#, { m, s in
                let raw = sub(m, 1, s)
                return (season, Int(raw) ?? chineseNumber(raw) ?? -1)
            }),
            (#"(?i)(?:^|[\s._\-\[(])EP?\.?\s?(\d{1,3})(?![\d])"#, { m, s in (season, int(m, 1, s)!) }),
        ]
        for (pattern, read) in strong {
            if let (m, ns) = firstMatch(pattern, in: name), let r = read(m, ns), r.episode >= 0 {
                let title = cleanTitle(String(ns.substring(to: m.range.location)))
                guard !title.isEmpty else { continue }
                return EpisodeInfo(title: title, season: r.season, episode: r.episode, strong: true)
            }
        }
        // Weak: "Show - 07", "Show [07]", "Show 07" (not a year or a resolution).
        let weak = [#"\s[-–]\s*(\d{1,3})(?:v\d)?(?![\d])"#, #"[\[【](\d{1,3})[\]】]"#, #"[\s_](\d{1,3})\s*$"#]
        for pattern in weak {
            if let (m, ns) = firstMatch(pattern, in: name), let ep = int(m, 1, ns), !looksLikeNoise(ep) {
                let title = cleanTitle(String(ns.substring(to: m.range.location)))
                guard !title.isEmpty, title.rangeOfCharacter(from: .letters) != nil else { continue }
                return EpisodeInfo(title: title, season: season, episode: ep, strong: false)
            }
        }
        return nil
    }

    /// Case, dots, dashes and spacing do not make a different show.
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"[._\-–]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 一 … 九十九, 一百零八, 两; nil if not a Chinese number.
    static func chineseNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        guard !s.isEmpty else { return nil }
        var total = 0, current = 0
        for c in s {
            if let d = digits[c] { current = d }
            else if c == "十" { total += (current == 0 ? 1 : current) * 10; current = 0 }
            else if c == "百" { total += (current == 0 ? 1 : current) * 100; current = 0 }
            else { return nil }
        }
        return total + current
    }

    // MARK: private

    private static func chineseSeason(in name: String) -> Int? {
        guard let (m, ns) = firstMatch(#"第\s*([0-9]{1,2}|[一二两三四五六七八九十]+)\s*季"#, in: name) else { return nil }
        let raw = sub(m, 1, ns)
        return Int(raw) ?? chineseNumber(raw)
    }

    /// Years, resolutions and frame sizes are not episode numbers.
    private static func looksLikeNoise(_ n: Int) -> Bool { [480, 576, 720, 1080, 2160].contains(n) || n >= 1900 }

    private static func cleanTitle(_ raw: String) -> String {
        var t = raw
        if let r = t.range(of: #"第\s*([0-9]{1,2}|[一二两三四五六七八九十]+)\s*季.*$"#, options: .regularExpression) { t.removeSubrange(r) }
        t = t.replacingOccurrences(of: #"[\[【(（][^\]】)）]*[\]】)）]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " -–_:：·"))
    }

    private static func firstMatch(_ pattern: String, in s: String) -> (NSTextCheckingResult, NSString)? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { ($0, ns) }
    }

    private static func sub(_ m: NSTextCheckingResult, _ i: Int, _ s: NSString) -> String {
        m.range(at: i).location == NSNotFound ? "" : s.substring(with: m.range(at: i))
    }

    private static func int(_ m: NSTextCheckingResult, _ i: Int, _ s: NSString) -> Int? { Int(sub(m, i, s)) }
}

/// A user's correction for one file (by content key, so it survives moves).
struct SeriesOverride: Equatable, Codable {
    var title: String?
    var season: Int?
    var episode: Int?
    /// "不是剧集": keep this file out of every show.
    var excluded = false

    init(title: String? = nil, season: Int? = nil, episode: Int? = nil, excluded: Bool = false) {
        self.title = title
        self.season = season
        self.episode = episode
        self.excluded = excluded
    }
}

/// Everything the series grouping needs to know about the user's corrections.
struct SeriesContext: Equatable {
    /// fileKey → correction.
    var files: [String: SeriesOverride] = [:]
    /// Normalised detected show name → the name the user gave the show.
    var aliases: [String: String] = [:]

    /// The episode info used for `item`: the user's correction, else the file name
    /// (with the user's show name, if they renamed the show). nil: not an episode.
    func info(for item: LibraryItem) -> EpisodeInfo? {
        let detected = EpisodeParser.parse(item.name)
        if let o = files[item.record.fileKey] {
            if o.excluded { return nil }
            guard let episode = o.episode ?? detected?.episode else { return nil }
            let title = o.title ?? detected.map(displayTitle) ?? ((item.record.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return EpisodeInfo(title: title, season: o.season, episode: episode, strong: true)
        }
        guard var d = detected else { return nil }
        d.title = displayTitle(d)
        return d
    }

    private func displayTitle(_ d: EpisodeInfo) -> String {
        aliases[EpisodeParser.normalizedTitle(d.title)] ?? d.title
    }
}

/// Saved corrections (small; kept with the app's preferences).
final class SeriesOverrideStore {
    static let filesKey = "videotool.series.files"
    static let aliasesKey = "videotool.series.aliases"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppData.defaults) { self.defaults = defaults }

    var context: SeriesContext {
        let files = defaults.data(forKey: Self.filesKey)
            .flatMap { try? JSONDecoder().decode([String: SeriesOverride].self, from: $0) } ?? [:]
        let aliases = defaults.dictionary(forKey: Self.aliasesKey) as? [String: String] ?? [:]
        return SeriesContext(files: files, aliases: aliases)
    }

    func set(_ override: SeriesOverride?, for fileKey: String) {
        var files = context.files
        files[fileKey] = override
        defaults.set(try? JSONEncoder().encode(files), forKey: Self.filesKey)
    }

    /// Every episode detected as `detected` is shown under `name` from now on.
    func setAlias(_ name: String, forDetected detected: String) {
        var aliases = context.aliases
        aliases[EpisodeParser.normalizedTitle(detected)] = name
        defaults.set(aliases, forKey: Self.aliasesKey)
    }
}
