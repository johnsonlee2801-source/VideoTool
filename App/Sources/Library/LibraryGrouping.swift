import Foundation

enum LibraryGroupingMode: String, CaseIterable {
    case all, folder, date, duration, resolution, duplicates, tag

    var title: String {
        switch self {
        case .all: return "全部视频"
        case .folder: return "按文件夹"
        case .date: return "按日期"
        case .duration: return "按时长"
        case .resolution: return "按清晰度"
        case .duplicates: return "重复文件"
        case .tag: return "按内容标签"
        }
    }
}

struct LibraryItem: Equatable {
    var record: MediaRecord
    var tags: [String]
    var starCount: Int = 0
    var name: String { (record.path as NSString).lastPathComponent }
}

struct LibrarySection: Equatable {
    var title: String
    var items: [LibraryItem]
}

/// Pure rules that turn library rows into the sections shown in the window.
/// Organising is virtual: nothing is moved on disk.
enum LibraryGrouping {
    enum DurationBucket: Int, CaseIterable {
        case underOneMinute, oneToTen, tenToThirty, thirtyToSixty, overAnHour, unknown
        var title: String {
            switch self {
            case .underOneMinute: return "1 分钟以内"
            case .oneToTen: return "1–10 分钟"
            case .tenToThirty: return "10–30 分钟"
            case .thirtyToSixty: return "30–60 分钟"
            case .overAnHour: return "1 小时以上"
            case .unknown: return "时长未知"
            }
        }
    }

    enum ResolutionBucket: Int, CaseIterable {
        case uhd, fullHD, hd, sd, unknown
        var title: String {
            switch self {
            case .uhd: return "4K 及以上"
            case .fullHD: return "1080p"
            case .hd: return "720p"
            case .sd: return "标清"
            case .unknown: return "清晰度未知"
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

    static func folderTitle(path: String, root: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        if dir == base { return "（根目录）" }
        if dir.hasPrefix(base + "/") { return String(dir.dropFirst(base.count + 1)) }
        return dir
    }

    /// Dates before 1971 mean "unknown" (missing metadata shows up as 1 Jan 1970 or distantPast).
    static func hasUsableDate(_ date: Date) -> Bool { date.timeIntervalSince1970 >= 31_536_000 }

    static func monthTitle(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0) 年 \(c.month ?? 0) 月"
    }

    static func sections(_ items: [LibraryItem], mode: LibraryGroupingMode, search: String = "",
                         calendar: Calendar = .current) -> [LibrarySection] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let filtered = needle.isEmpty ? items : items.filter { item in
            item.name.localizedCaseInsensitiveContains(needle) || item.tags.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        guard !filtered.isEmpty else { return [] }
        // Name order, then full path, so equal names never reshuffle between reloads.
        let byName: (LibraryItem, LibraryItem) -> Bool = {
            let c = $0.name.localizedStandardCompare($1.name)
            return c == .orderedSame ? $0.record.path < $1.record.path : c == .orderedAscending
        }

        switch mode {
        case .all:
            return [LibrarySection(title: "全部视频", items: filtered.sorted(by: byName))]

        case .folder:
            let groups = Dictionary(grouping: filtered) { folderTitle(path: $0.record.path, root: $0.record.root) }
            return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { LibrarySection(title: $0, items: groups[$0]!.sorted(by: byName)) }

        case .date:
            let known = filtered.filter { hasUsableDate($0.record.modified) }
            let unknown = filtered.filter { !hasUsableDate($0.record.modified) }
            let groups = Dictionary(grouping: known) { calendar.dateComponents([.year, .month], from: $0.record.modified) }
            var out = groups.keys.sorted { ($0.year!, $0.month!) > ($1.year!, $1.month!) }.map { key in
                let items = groups[key]!
                return LibrarySection(title: monthTitle(items[0].record.modified, calendar: calendar), items: items.sorted(by: byName))
            }
            if !unknown.isEmpty { out.append(LibrarySection(title: "日期未知", items: unknown.sorted(by: byName))) }
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
                .map { LibrarySection(title: "\($0[0].name) 等 \($0.count) 份相同内容", items: $0) }

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
                .map { LibrarySection(title: $0, items: groups[$0]!.sorted(by: byName)) }
            if !untagged.isEmpty { out.append(LibrarySection(title: "未识别", items: untagged.sorted(by: byName))) }
            return out
        }
    }
}
