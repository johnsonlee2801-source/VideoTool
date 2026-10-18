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
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) }) {
        self.store = store
        self.stars = stars
        self.makeIndexer = makeIndexer
        self.thumbnailDirectory = thumbnailDirectory
        self.background = background
        self.main = main
        reload()
    }

    var sections: [LibrarySection] { LibraryGrouping.sections(items, mode: mode, search: search) }

    func thumbnailURL(for item: LibraryItem) -> URL {
        LibraryIndexer.thumbnailURL(forKey: item.record.fileKey, in: thumbnailDirectory)
    }

    // MARK: folders

    func addRoot(_ path: String, recursive: Bool = true) {
        notice = nil
        let target = LibraryStore.normalized(path)
        switch (try? store.addRoot(target, recursive: recursive)) ?? .added {
        case .alreadyCovered(let parent):
            notice = "「\((target as NSString).lastPathComponent)」已在视频库的「\((parent as NSString).lastPathComponent)」里，不用重复添加。"
            onChange?()
            return
        case .absorbed(let children):
            notice = "已把 \(children.count) 个子文件夹合并进「\((target as NSString).lastPathComponent)」。"
        case .added:
            break
        }
        reload()
        enqueue([target])
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
        try? store.removeRoot(path)
        unavailableRoots.removeAll { $0 == path }
        reload()
    }

    func cancelScan() {
        token?.cancel()
        queuedRoots.removeAll()
    }

    // MARK: data

    func reload() {
        rootEntries = (try? store.rootEntries()) ?? []
        roots = rootEntries.map(\.path)
        let tags = (try? store.allTags()) ?? [:]
        let counts: [String: Int] = (try? stars?.counts()) ?? [:]
        items = ((try? store.media(inRoot: nil)) ?? []).map {
            LibraryItem(record: $0, tags: tags[$0.fileKey] ?? [], starCount: counts[$0.fileKey] ?? 0)
        }
        onChange?()
    }

    var statusText: String {
        if isIndexing {
            guard let p = progress, p.total > 0 else { return "正在扫描…" }
            return "正在扫描 \((p.root as NSString).lastPathComponent)… \(p.done)/\(p.total)"
        }
        var parts = ["共 \(items.count) 个视频"]
        if let s = lastSummary {
            if s.added > 0 { parts.append("新增 \(s.added)") }
            if s.updated > 0 { parts.append("更新 \(s.updated)") }
            if s.removed > 0 { parts.append("移除 \(s.removed)") }
            if s.unreadable > 0 { parts.append("\(s.unreadable) 个无法读取") }
            if s.probeFailed > 0 { parts.append("\(s.probeFailed) 个信息不全") }
        }
        if !unavailableRoots.isEmpty { parts.append("\(unavailableRoots.count) 个文件夹暂时无法访问") }
        let cloud = items.filter { $0.record.status == .cloudOnly }.count
        if cloud > 0 { parts.append("\(cloud) 个在 iCloud 未下载") }
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
            notice = "暂时无法打开视频库数据库，请稍后点「重新扫描」。"
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
                self.unavailableRoots = unavailable
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
