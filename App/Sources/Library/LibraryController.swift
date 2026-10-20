import Foundation

/// Thread-safe "stop" flag for one scan batch (written on main, read on the scan queue).
final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// State behind the library window: watched folders, indexed videos, grouping
/// and search. Scans run one batch at a time in the background; results land on
/// main. AppKit-free so it can be tested with hand-driven queues.
final class LibraryController {
    typealias Executor = (@escaping () -> Void) -> Void

    private let store: LibraryStore
    private let stars: BookmarkStore?
    /// Each scan batch gets its own indexer (with its own database connection).
    /// nil means the database could not be opened right now.
    private let makeIndexer: () -> LibraryIndexer?
    private let thumbnailDirectory: URL
    private let background: Executor
    private let main: Executor
    private let history: WatchHistoryStore
    private let seriesStore: SeriesOverrideStore

    private(set) var roots: [String] = []
    /// Library folders with their "whole / this layer only" flag.
    private(set) var rootEntries: [LibraryRoot] = []
    private(set) var items: [LibraryItem] = []
    private(set) var isIndexing = false
    private(set) var progress: LibraryIndexer.Progress?
    private(set) var lastSummary: LibraryIndexer.Summary?
    /// Folders that could not be reached in the last pass (unplugged drive, no permission).
    private(set) var unavailableRoots: [String] = []
    /// One-off message for the user (e.g. why adding a folder changed nothing).
    private(set) var notice: String?
    private var queuedRoots: [String] = []
    private var token: CancellationToken?
    private var lastProgressSignal = Date.distantPast

    var mode: LibraryGroupingMode = .all { didSet { onChange?() } }
    var search = "" { didSet { onChange?() } }
    /// Items or folders changed: reload the whole window.
    var onChange: (() -> Void)?
    /// Scan progress moved: update the status line only (throttled to ~5 per second).
    var onProgress: (() -> Void)?

    init(store: LibraryStore, stars: BookmarkStore?, makeIndexer: @escaping () -> LibraryIndexer?,
         thumbnailDirectory: URL = LibraryIndexer.defaultThumbnailDirectory,
         background: @escaping Executor = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) },
         history: WatchHistoryStore = WatchHistoryStore(), series: SeriesOverrideStore = SeriesOverrideStore()) {
        self.store = store
        self.stars = stars
        self.makeIndexer = makeIndexer
        self.thumbnailDirectory = thumbnailDirectory
        self.background = background
        self.main = main
        self.history = history
        self.seriesStore = series
        reload()
    }

    var sections: [LibrarySection] {
        LibraryGrouping.sections(items, mode: mode, search: search, series: seriesStore.context)
    }

    // MARK: series corrections

    /// What the series view currently thinks `item` is (nil: not an episode).
    func episodeInfo(for item: LibraryItem) -> EpisodeInfo? { seriesStore.context.info(for: item) }

    /// Saves a correction for this file; `renameShow` also renames every episode
    /// detected under the same show name. nil override: back to automatic.
    func saveSeries(_ override: SeriesOverride?, for item: LibraryItem, renameShow: Bool = false) {
        seriesStore.set(override, for: item.record.fileKey)
        if renameShow, let title = override?.title, let detected = EpisodeParser.parse(item.name) {
            seriesStore.setAlias(title, forDetected: detected.title)
        }
        onChange?()
    }

    func thumbnailURL(for item: LibraryItem) -> URL {
        LibraryIndexer.thumbnailURL(forKey: item.record.fileKey, in: thumbnailDirectory)
    }

    // MARK: folders

    /// Returns false if the folder could not be saved (the notice says why).
    @discardableResult
    func addRoot(_ path: String, recursive: Bool = true) -> Bool {
        notice = nil
        let target = LibraryStore.normalized(path)
        let result: AddRootResult
        do { result = try store.addRoot(target, recursive: recursive) } catch {
            notice = L("无法加入视频库：%@", error.localizedDescription)    // nothing saved: nothing to scan
            onChange?()
            return false
        }
        switch result {
        case .alreadyCovered(let parent):
            notice = L("「%1$@」已在视频库的「%2$@」里，不用重复添加。", String(describing: (target as NSString).lastPathComponent), String(describing: (parent as NSString).lastPathComponent))
            onChange?()
            return true
        case .absorbed(let children):
            notice = L("已把 %1$@ 个子文件夹合并进「%2$@」。", String(describing: children.count), String(describing: (target as NSString).lastPathComponent))
        case .added:
            break
        }
        reload()
        enqueue([target])
        return true
    }

    func rescanAll() { enqueue(roots) }

    /// Picks up new or changed videos in one library folder (incremental).
    func rescan(_ root: String) {
        guard roots.contains(root) else { return }
        enqueue([root])
    }

    /// Stops watching a folder. Its videos leave the library; the files stay where they are.
    /// A scan already running for it stops at its next file (the indexer re-checks the folder).
    func removeRoot(_ path: String) {
        queuedRoots.removeAll { $0 == path }
        do { try store.removeRoot(path) } catch {
            notice = L("无法移出视频库：%@", error.localizedDescription)
            onChange?()
            return
        }
        unavailableRoots.removeAll { $0 == path }
        reload()
    }

    func cancelScan() {
        token?.cancel()
        queuedRoots.removeAll()
    }

    // MARK: data

    func reload() {
        // A read error keeps what is on screen rather than showing an empty library.
        let entries: [LibraryRoot], media: [MediaRecord]
        do { entries = try store.rootEntries(); media = try store.media(inRoot: nil) } catch {
            notice = L("暂时无法读取视频库：%@", error.localizedDescription)
            onChange?()
            return
        }
        rootEntries = entries
        roots = rootEntries.map(\.path)
        let tags = (try? store.allTags()) ?? [:]
        let counts: [String: Int] = (try? stars?.counts()) ?? [:]
        let watched = history.all
        items = media.map {
            LibraryItem(record: $0, tags: tags[$0.fileKey] ?? [], starCount: counts[$0.fileKey] ?? 0, watch: watched[$0.path])
        }
        onChange?()
    }

    var statusText: String {
        if isIndexing {
            guard let p = progress, p.total > 0 else { return L("正在扫描…") }
            return L("正在扫描 %1$@… %2$@/%3$@", String(describing: (p.root as NSString).lastPathComponent), String(describing: p.done), String(describing: p.total))
        }
        var parts = [L("共 %@ 个视频", String(describing: items.count))]
        if let s = lastSummary {
            if s.added > 0 { parts.append(L("新增 %@", String(describing: s.added))) }
            if s.updated > 0 { parts.append(L("更新 %@", String(describing: s.updated))) }
            if s.removed > 0 { parts.append(L("移除 %@", String(describing: s.removed))) }
            if s.unreadable > 0 { parts.append(L("%@ 个无法读取", String(describing: s.unreadable))) }
            if s.probeFailed > 0 { parts.append(L("%@ 个信息不全", String(describing: s.probeFailed))) }
        }
        if !unavailableRoots.isEmpty { parts.append(L("%@ 个文件夹暂时无法访问", String(describing: unavailableRoots.count))) }
        let cloud = items.filter { $0.record.status == .cloudOnly }.count
        if cloud > 0 { parts.append(L("%@ 个在 iCloud 未下载", String(describing: cloud))) }
        return parts.joined(separator: " · ")
    }

    // MARK: scanning

    private func enqueue(_ paths: [String]) {
        for p in paths where !queuedRoots.contains(p) { queuedRoots.append(p) }
        startNextIfIdle()
        onChange?()
    }

    private func startNextIfIdle() {
        guard !isIndexing, !queuedRoots.isEmpty else { return }
        guard let indexer = makeIndexer() else {
            queuedRoots.removeAll()
            notice = L("暂时无法打开视频库数据库，请稍后点「重新扫描」。")
            onChange?()
            return
        }
        let batch = queuedRoots
        queuedRoots.removeAll()
        let token = CancellationToken()
        self.token = token
        isIndexing = true
        progress = nil
        background { [weak self] in
            var total = LibraryIndexer.Summary()
            var unavailable: [String] = []
            for root in batch where !token.isCancelled {
                let s = indexer.index(root: root, progress: { p in
                    self?.main { self?.report(p) }
                }, isCancelled: { token.isCancelled })
                total.added += s.added; total.updated += s.updated; total.unchanged += s.unchanged
                total.removed += s.removed; total.unreadable += s.unreadable; total.probeFailed += s.probeFailed
                if s.unavailable { unavailable.append(root) }
            }
            self?.main {
                guard let self else { return }
                self.isIndexing = false
                self.progress = nil
                self.lastSummary = total
                // Only the folders checked in this pass change status.
                self.unavailableRoots = self.unavailableRoots.filter { !batch.contains($0) } + unavailable
                self.token = nil
                self.reload()                      // the one full refresh for this pass
                self.startNextIfIdle()
            }
        }
    }

    private func report(_ p: LibraryIndexer.Progress) {
        progress = p
        let now = Date()
        guard p.done == p.total || now.timeIntervalSince(lastProgressSignal) >= 0.2 else { return }
        lastProgressSignal = now
        onProgress?()
    }
}
