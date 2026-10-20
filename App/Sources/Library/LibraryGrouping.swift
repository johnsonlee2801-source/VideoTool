import Foundation

enum LibraryGroupingMode: String, CaseIterable {
    case all, series, folder, date, duration, resolution, duplicates, tag

    var title: String {
        switch self {
        case .all: return L("全部视频")
        case .series: return L("按剧集")
        case .folder: return L("按文件夹")
        case .date: return L("按日期")
        case .duration: return L("按时长")
        case .resolution: return L("按清晰度")
        case .duplicates: return L("重复文件")
        case .tag: return L("按内容标签")
        }
    }
}

struct LibraryItem: Equatable {
    var record: MediaRecord
    var tags: [String]
    var starCount: Int = 0
    /// How far it has been watched (nil: never opened).
    var watch: WatchEntry?
    var name: String { (record.path as NSString).lastPathComponent }
}

struct LibrarySection: Equatable {
    var title: String
    var items: [LibraryItem]
}

/// Pure rules that turn library rows into the sections shown in the window.
/// Organising is virtual: nothing is moved on disk.
enum LibraryGrouping {
    static let continueWatchingLimit = 12

    enum DurationBucket: Int, CaseIterable {
        case underOneMinute, oneToTen, tenToThirty, thirtyToSixty, overAnHour, unknown
        var title: String {
            switch self {
            case .underOneMinute: return L("1 分钟以内")
            case .oneToTen: return L("1–10 分钟")
            case .tenToThirty: return L("10–30 分钟")
            case .thirtyToSixty: return L("30–60 分钟")
            case .overAnHour: return L("1 小时以上")
            case .unknown: return L("时长未知")
            }
        }
    }

    enum ResolutionBucket: Int, CaseIterable {
        case uhd, fullHD, hd, sd, unknown
        var title: String {
            switch self {
            case .uhd: return L("4K 及以上")
            case .fullHD: return "1080p"
            case .hd: return "720p"
            case .sd: return L("标清")
            case .unknown: return L("清晰度未知")
            }
        }
    }

    static func durationBucket(_ seconds: Double) -> DurationBucket {
        guard seconds.isFinite, seconds > 0 else { return .unknown }
        switch seconds {
        case ...60: return .underOneMinute
        case ...600: return .oneToTen
        case ...1800: return .tenToThirty
        case ...3600: return .thirtyToSixty
        default: return .overAnHour
        }
    }

    /// Uses the long side as well as the short side, so letterboxed and portrait videos land correctly.
    static func resolutionBucket(width: Int, height: Int) -> ResolutionBucket {
        let long = max(width, height), short = min(width, height)
        guard long > 0, short > 0 else { return .unknown }
        if short >= 2160 || long >= 3840 { return .uhd }
        if short >= 1080 || long >= 1920 { return .fullHD }
        if short >= 720 || long >= 1280 { return .hd }
        return .sd
    }

    /// Started (past the first seconds), not finished; most recently watched first.
    static func continueWatching(_ items: [LibraryItem]) -> [LibraryItem] {
        items.filter { $0.watch.map { !$0.isWatched && $0.position >= ResumePositionStore.minimumPosition } ?? false }
            .sorted { $0.watch!.watchedAt > $1.watch!.watchedAt }
            .prefix(continueWatchingLimit).map { $0 }
    }

    /// One section per show and season, episodes in order; the rest under 其他视频.
    /// A show detected only from weak hints ("Name - 07") needs at least two episodes.
    static func seriesSections(_ items: [LibraryItem], context: SeriesContext,
                               byName: (LibraryItem, LibraryItem) -> Bool) -> [LibrarySection] {
        struct Key: Hashable { var title: String; var season: Int? }
        var groups: [Key: [(LibraryItem, EpisodeInfo)]] = [:]
        var others: [LibraryItem] = []
        for item in items {
            guard let info = context.info(for: item) else { others.append(item); continue }
            groups[Key(title: EpisodeParser.normalizedTitle(info.title), season: info.season), default: []].append((item, info))
        }
        var shows: [(title: String, season: Int?, items: [LibraryItem])] = []
        for (key, members) in groups {
            // Two copies of one weakly named episode are not a series: count distinct episodes.
            guard Set(members.map(\.1.episode)).count > 1 || members.contains(where: { $0.1.strong }) else {
                others += members.map(\.0); continue
            }
            let sorted = members.sorted { $0.1.episode != $1.1.episode ? $0.1.episode < $1.1.episode : byName($0.0, $1.0) }
            // Show the spelling most episodes use (ties: the first episode's).
            let spellings = Dictionary(grouping: sorted.map(\.1.title), by: { $0 })
            let title = sorted.map(\.1.title).max { spellings[$0]!.count < spellings[$1]!.count } ?? sorted[0].1.title
            shows.append((title, key.season, sorted.map(\.0)))
        }
        shows.sort {
            let c = $0.title.localizedStandardCompare($1.title)
            return c == .orderedSame ? ($0.season ?? 0) < ($1.season ?? 0) : c == .orderedAscending
        }
        var out = shows.map { s in
            LibrarySection(title: [s.title, s.season.map { L("第 %@ 季", String(describing: $0)) }, L("%@ 集", String(describing: s.items.count))].compactMap { $0 }.joined(separator: " · "),
                           items: s.items)
        }
        if !others.isEmpty { out.append(LibrarySection(title: L("其他视频"), items: others.sorted(by: byName))) }
        return out
    }

    static func folderTitle(path: String, root: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        if dir == base { return L("（根目录）") }
        if dir.hasPrefix(base + "/") { return String(dir.dropFirst(base.count + 1)) }
        return dir
    }

    /// Dates before 1971 mean "unknown" (missing metadata shows up as 1 Jan 1970 or distantPast).
    static func hasUsableDate(_ date: Date) -> Bool { date.timeIntervalSince1970 >= 31_536_000 }

    static func monthTitle(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return L("%1$@ 年 %2$@ 月", String(describing: c.year ?? 0), String(describing: c.month ?? 0))
    }

    static func sections(_ items: [LibraryItem], mode: LibraryGroupingMode, search: String = "",
                         series: SeriesContext = SeriesContext(), calendar: Calendar = .current) -> [LibrarySection] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let filtered = needle.isEmpty ? items : items.filter { item in
            item.name.localizedCaseInsensitiveContains(needle)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(needle) || L($0).localizedCaseInsensitiveContains(needle) }
        }
        guard !filtered.isEmpty else { return [] }
        // Name order, then full path, so equal names never reshuffle between reloads.
        let byName: (LibraryItem, LibraryItem) -> Bool = {
            let c = $0.name.localizedStandardCompare($1.name)
            return c == .orderedSame ? $0.record.path < $1.record.path : c == .orderedAscending
        }

        switch mode {
        case .all:
            let all = LibrarySection(title: L("全部视频"), items: filtered.sorted(by: byName))
            // Unfinished videos first, most recent first (not while searching).
            let inProgress = needle.isEmpty ? continueWatching(filtered) : []
            return inProgress.isEmpty ? [all] : [LibrarySection(title: L("继续观看"), items: inProgress), all]

        case .series:
            return seriesSections(filtered, context: series, byName: byName)

        case .folder:
            // By the folder itself, not its title: "Trips" in two library folders stays apart
            // (audit 2026-10-20); clashing titles are prefixed with their library folder's name.
            let groups = Dictionary(grouping: filtered) { ($0.record.path as NSString).deletingLastPathComponent }
            var titles = groups.mapValues { folderTitle(path: $0[0].record.path, root: $0[0].record.root) }
            let clashing = Dictionary(grouping: titles.keys, by: { titles[$0]! }).filter { $0.value.count > 1 }
            for dirs in clashing.values {
                for dir in dirs {
                    let rootName = (groups[dir]![0].record.root as NSString).lastPathComponent
                    let parent = ((groups[dir]![0].record.root as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    titles[dir] = [parent, rootName, titles[dir]!].filter { !$0.isEmpty && $0 != "/" }.joined(separator: " › ")
                }
            }
            return groups.keys.sorted { titles[$0]!.localizedStandardCompare(titles[$1]!) == .orderedAscending }
                .map { LibrarySection(title: titles[$0]!, items: groups[$0]!.sorted(by: byName)) }

        case .date:
            let known = filtered.filter { hasUsableDate($0.record.modified) }
            let unknown = filtered.filter { !hasUsableDate($0.record.modified) }
            // Keyed by each month's start date: year numbers alone do not sort (or even
            // separate) months in calendars with eras, such as the Japanese one.
            let groups = Dictionary(grouping: known) { calendar.dateInterval(of: .month, for: $0.record.modified)?.start ?? $0.record.modified }
            var out = groups.keys.sorted(by: >).map { key in
                let items = groups[key]!
                return LibrarySection(title: monthTitle(items[0].record.modified, calendar: calendar), items: items.sorted(by: byName))
            }
            if !unknown.isEmpty { out.append(LibrarySection(title: L("日期未知"), items: unknown.sorted(by: byName))) }
            return out

        case .duration:
            let groups = Dictionary(grouping: filtered) { durationBucket($0.record.duration) }
            return DurationBucket.allCases.compactMap { b in
                groups[b].map { LibrarySection(title: b.title, items: $0.sorted(by: byName)) }
            }

        case .resolution:
            let groups = Dictionary(grouping: filtered) { resolutionBucket(width: $0.record.width, height: $0.record.height) }
            return ResolutionBucket.allCases.compactMap { b in
                groups[b].map { LibrarySection(title: b.title, items: $0.sorted(by: byName)) }
            }

        case .duplicates:
            // Same OSHash *and* same content check; cloud-only files are never compared.
            return Dictionary(grouping: filtered.filter { $0.record.status != .cloudOnly }) {
                $0.record.fileKey + "|" + $0.record.contentCheck
            }.values
                .filter { $0.count > 1 }
                .map { $0.sorted(by: byName) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : byName($0[0], $1[0]) }
                .map { LibrarySection(title: L("%1$@ 等 %2$@ 份相同内容", String(describing: $0[0].name), String(describing: $0.count)), items: $0) }

        case .tag:
            var groups: [String: [LibraryItem]] = [:]
            var untagged: [LibraryItem] = []
            for item in filtered {
                if item.tags.isEmpty { untagged.append(item) }
                for t in item.tags { groups[t, default: []].append(item) }
            }
            var out = groups.keys
                .sorted { groups[$0]!.count != groups[$1]!.count ? groups[$0]!.count > groups[$1]!.count
                                                                  : $0.localizedStandardCompare($1) == .orderedAscending }
                .map { LibrarySection(title: L($0), items: groups[$0]!.sorted(by: byName)) }     // stored in Chinese
            if !untagged.isEmpty { out.append(LibrarySection(title: L("未识别"), items: untagged.sorted(by: byName))) }
            return out
        }
    }
}
