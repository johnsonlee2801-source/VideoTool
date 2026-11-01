import Foundation

struct RecentPlaybackItem {
    var path: String
    var watch: WatchEntry
    var indexed: LibraryItem?
}

enum RecentPlayback {
    static func items(history: [String: WatchEntry], indexed: [LibraryItem], search: String = "") -> [RecentPlaybackItem] {
        var byPath: [String: LibraryItem] = [:]
        for item in indexed { byPath[item.record.path] = item }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.compactMap { path, watch -> RecentPlaybackItem? in
            let item = byPath[path]
            guard needle.isEmpty || (path as NSString).lastPathComponent.localizedCaseInsensitiveContains(needle)
                || (item?.tags.contains { $0.localizedCaseInsensitiveContains(needle) || L($0).localizedCaseInsensitiveContains(needle) } ?? false)
            else { return nil }
            return RecentPlaybackItem(path: path, watch: watch, indexed: item)
        }.sorted {
            $0.watch.watchedAt == $1.watch.watchedAt ? $0.path < $1.path : $0.watch.watchedAt > $1.watch.watchedAt
        }
    }
}
