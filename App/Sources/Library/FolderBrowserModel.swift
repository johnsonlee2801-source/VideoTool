import Foundation

struct FolderBrowserNode: Equatable {
    var path: String
    /// Includes descendants, not just this layer; the UI labels that explicitly.
    var videoCount: Int
}

struct FolderBrowserVideo: Equatable {
    var path: String
    var item: LibraryItem?
    var watch: WatchEntry? { item?.watch }
}

struct FolderBrowserSnapshot {
    var folders: [FolderBrowserNode]
    var videos: [FolderBrowserVideo]
}

enum FolderWatchFilter: Int, CaseIterable {
    case all, unseen, unfinished, watched
    var title: String {
        switch self {
        case .all: return L("全部视频")
        case .unseen: return L("未观看")
        case .unfinished: return L("继续观看")
        case .watched: return L("已看完")
        }
    }
    func accepts(_ entry: WatchEntry?) -> Bool {
        switch self {
        case .all: return true
        case .unseen: return entry == nil
        case .unfinished: return entry.map { !$0.isWatched } ?? false
        case .watched: return entry?.isWatched == true
        }
    }
}

enum FolderBrowserModel {
    static func contains(_ path: String, in directory: String) -> Bool {
        path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
    }
    static func snapshot(path: String?, roots: [String], items: [LibraryItem], search: String = "",
                         tag: String? = nil, watch: FolderWatchFilter = .all) -> FolderBrowserSnapshot {
        var unique: [String: LibraryItem] = [:]
        for item in items where unique[item.record.path] == nil { unique[item.record.path] = item }
        let all = Array(unique.values)
        guard let path else {
            return FolderBrowserSnapshot(folders: FolderDirectory.sorted(roots).map { root in
                FolderBrowserNode(path: root, videoCount: all.filter { contains($0.record.path, in: root) }.count)
            }, videos: [])
        }
        var children: [String: Int] = [:]
        for item in all where contains(item.record.path, in: path) {
            let directory = (item.record.path as NSString).deletingLastPathComponent
            guard directory != path else { continue }
            let relative = String(directory.dropFirst(path == "/" ? 1 : path.count + 1))
            if let first = relative.split(separator: "/").first {
                children[(path as NSString).appendingPathComponent(String(first)), default: 0] += 1
            }
        }
        let folders = FolderDirectory.sorted(Array(children.keys)).map { child in
            FolderBrowserNode(path: child, videoCount: children[child] ?? 0)
        }
        let videos = all.filter { ($0.record.path as NSString).deletingLastPathComponent == path }
            .map { FolderBrowserVideo(path: $0.record.path, item: $0) }
        return FolderBrowserSnapshot(folders: folders, videos: filter(videos, search: search, tag: tag, watch: watch))
    }
    static func filter(_ videos: [FolderBrowserVideo], search: String, tag: String?, watch: FolderWatchFilter,
                       history: [String: WatchEntry] = [:]) -> [FolderBrowserVideo] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = videos.filter { video in
            let tags = video.item?.tags ?? []
            return watch.accepts(history[video.path] ?? video.watch)
                && (tag == nil || tags.contains(tag!))
                && (needle.isEmpty || (video.path as NSString).lastPathComponent.localizedCaseInsensitiveContains(needle)
                    || tags.contains { $0.localizedCaseInsensitiveContains(needle) || L($0).localizedCaseInsensitiveContains(needle) })
        }
        let byPath = Dictionary(filtered.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return FolderDirectory.sorted(Array(byPath.keys)).compactMap { byPath[$0] }
    }
}
