import Foundation

enum BookmarkFeedback: Equatable {
    case added(Bookmark)
    case undone
    /// The file is still being identified (fingerprint in progress).
    case notReady
    /// The file could not be identified, so it cannot hold stars.
    case unavailable
}

/// Stars for the file currently playing: identify the file, add/undo with B,
/// navigate, edit, delete. AppKit-free so it can be tested with a fake engine
/// and hand-driven queues; the window controller renders `bookmarks`.
final class BookmarkController {
    typealias Executor = (@escaping () -> Void) -> Void

    private let store: BookmarkStore
    private let engine: PlayerEngine
    private let now: () -> Date
    private let thumbnailDirectory: URL?
    private let thumbnails: ThumbnailMaker?
    private let fingerprint: (String) -> String?
    private let background: Executor
    private let main: Executor
    /// Serial: writes land in the order they were made.
    private let persist: Executor
    /// Writes use their own connection: in WAL mode the main thread's reads never wait
    /// behind a write that is itself waiting for the indexer's lock.
    private let writer: BookmarkStore
    /// While writes for a file are queued, its latest star list lives here so a reopen
    /// shows it without waiting for the database. Guarded by `pendingLock`.
    private let pendingLock = NSLock()
    private var pending: [String: Pending] = [:]
    /// Edits made per file key, and keys whose correction waits for their queued writes.
    private var versions: [String: Int] = [:]
    private var unreconciled: Set<String> = []
    private struct Pending {
        var count: Int
        var stars: [Bookmark]      // the list as shown, including queued changes
        let base: [Bookmark]       // the list before the first queued change: last known stored
        var failed = false
    }

    private(set) var fileKey: String?
    private(set) var bookmarks: [Bookmark] = []
    private var filePath: String?
    private var identifying = false
    private var unidentifiable = false
    /// Bumped on every open/close so late fingerprint results for an older file are dropped.
    private var generation = 0
    /// Star the last ⌥←/⌥→ jumped to, and when (mpv reports the new position a little later).
    private var landed: (star: Double, at: Date, from: Double?)?

    var onChange: (([Bookmark]) -> Void)?
    /// A star's thumbnail finished; only the preview needs refreshing (not the list).
    var onThumbnailReady: ((UUID) -> Void)?
    var onError: ((Error) -> Void)?
    /// Queued writes for a file reached the database (star counts elsewhere may change).
    var onStored: (() -> Void)?

    init(store: BookmarkStore, engine: PlayerEngine, now: @escaping () -> Date = Date.init,
         thumbnailDirectory: URL? = BookmarkController.defaultThumbnailDirectory,
         thumbnails: ThumbnailMaker? = MPVThumbnailMaker(),
         fingerprint: @escaping (String) -> String? = FileFingerprint.key(forTarget:),
         background: @escaping Executor = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) },
         persist: Executor? = nil) {
        let writes = DispatchQueue(label: "VideoTool.bookmarks.persist", qos: .utility)
        self.persist = persist ?? { writes.async(execute: $0) }
        // Degraded mode: if a second connection cannot be opened, writes share the reader's
        // connection; they are still off the main thread, but a read can then wait behind one.
        self.writer = (try? BookmarkStore(path: store.path)) ?? store
        self.store = store
        self.engine = engine
        self.now = now
        self.thumbnailDirectory = thumbnailDirectory
        self.thumbnails = thumbnails
        self.fingerprint = fingerprint
        self.background = background
        self.main = main
    }

    static var defaultThumbnailDirectory: URL {
        AppData.directory.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    var isReady: Bool { fileKey != nil }

    // MARK: file lifecycle

    /// Identify `path` off the main thread, then load its stars. Opening another
    /// file (or closing) before the result arrives discards it.
    func open(path: String) {
        fileClosed()
        identifying = true
        let token = generation
        background { [fingerprint] in
            let key = fingerprint(path)
            self.main {
                guard token == self.generation else { return }      // a newer file took over
                self.identifying = false
                if let key { self.fileOpened(key: key, path: path) } else { self.unidentifiable = true }
            }
        }
    }

    /// Stable page identity; never hash the CDN address or generate local thumbnails.
    func openNetwork(_ video: NetworkVideo) {
        fileClosed()
        fileOpened(key: video.key, path: video.url.absoluteString)
        filePath = nil
    }

    /// Load stars for an already-identified file.
    func fileOpened(key: String, path: String) {
        fileKey = key
        filePath = path
        identifying = false
        unidentifiable = false
        landed = nil
        // Every load writes this; under an indexing writer it can wait on the busy timeout.
        let writer = self.writer
        persist { [weak self] in
            do { try writer.rememberFile(key: key, path: path) }
            catch { self?.main { self?.onError?(error) } }
        }
        reload()
    }

    func fileClosed() {
        generation += 1
        fileKey = nil
        filePath = nil
        identifying = false
        unidentifiable = false
        landed = nil
        bookmarks = []
        onChange?(bookmarks)
    }

    // MARK: B key

    @discardableResult
    func toggleAtCurrentTime() -> BookmarkFeedback? {
        guard let fileKey else {
            if identifying { return .notReady }
            if unidentifiable { return .unavailable }
            return nil
        }
        let time = engine.state.timePos
        switch BookmarkNavigator.toggle(at: time, now: now(), existing: bookmarks, speed: engine.state.speed) {
        case .undo(let id):
            guard remove(id) else { return nil }
            return .undone
        case .add:
            // Shown at once; stored by the queue. A failed insert takes the star back off.
            let b = Bookmark(id: UUID(), fileKey: fileKey, time: time, endTime: nil, note: "", createdAt: now())
            let before = bookmarks
            publish(bookmarks + [b])
            write(fileKey, before: before) { try $0.insert(b) }
            requestThumbnail(for: b)
            return .added(b)
        }
    }

    // MARK: navigation

    @discardableResult
    func jumpToNext() -> Bool {
        let current = engine.state.timePos
        guard let t = BookmarkNavigator.next(after: current, in: bookmarks.map(\.time), landedOn: landedStar(current)) else {
            return false
        }
        land(on: t)
        return true
    }

    @discardableResult
    func jumpToPrevious() -> Bool {
        let current = engine.state.timePos
        guard let t = BookmarkNavigator.previous(before: current, in: bookmarks.map(\.time), landedOn: landedStar(current)) else {
            return false
        }
        land(on: t)
        return true
    }

    func jump(to b: Bookmark) { land(on: b.time) }

    /// Where a click on the progress bar should seek: 2 s before a nearby star, else the click.
    func seekTarget(forClickAt time: Double, tolerance: Double) -> Double {
        if let star = BookmarkNavigator.snap(time, to: bookmarks.map(\.time), tolerance: tolerance) {
            landed = (star, now(), engine.state.timePos)
            return BookmarkNavigator.jumpTarget(star)
        }
        landed = nil
        return time
    }

    private func land(on star: Double) {
        landed = (star, now(), engine.state.timePos)
        engine.seek(to: BookmarkNavigator.jumpTarget(star))
    }

    /// The star we are "at" after a jump: trusted for a moment even if mpv still
    /// reports the old position, and afterwards while the playhead is still in the
    /// stretch between the landing point and the star.
    private func landedStar(_ current: Double) -> Double? {
        guard let landed else { return nil }
        // Right after a jump mpv may still report the old position: trust the star then,
        // but not once the playhead has visibly moved on (at 6× it passes the next star
        // within a second; audit 2026-10-20).
        let stale = landed.from.map { abs(current - $0) < 0.75 } ?? true
        if now().timeIntervalSince(landed.at) < 1.5 && stale { return landed.star }
        let target = BookmarkNavigator.jumpTarget(landed.star)
        if current >= target - 0.25 && current <= landed.star + BookmarkNavigator.previousGrace { return landed.star }
        return nil
    }

    // MARK: editing

    func updateNote(_ id: UUID, _ note: String) {
        guard let fileKey, let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let before = bookmarks
        var stars = bookmarks; stars[index].note = note
        publish(stars)
        write(fileKey, before: before) { try $0.updateNote(id: id, note: note) }
    }

    func delete(_ id: UUID) { remove(id) }

    /// Off the list at once; the picture goes only once the row is really deleted,
    /// and a failed delete puts the star back (audit 2026-10-20 / 2026-11-07).
    @discardableResult
    private func remove(_ id: UUID) -> Bool {
        guard let fileKey, bookmarks.contains(where: { $0.id == id }) else { return false }
        let before = bookmarks
        publish(bookmarks.filter { $0.id != id })
        let directory = thumbnailDirectory
        write(fileKey, before: before) { store in
            try store.delete(id: id)
            if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).jpg")) }
        }
        return true
    }

    private func publish(_ stars: [Bookmark]) {
        bookmarks = stars.sorted { ($0.time, $0.createdAt) < ($1.time, $1.createdAt) }
        onChange?(bookmarks)
    }

    /// Queues one write for `key`; `before` is the list as it was before this change.
    /// When the last queued write for the key finishes and something failed, the list is
    /// reconciled with the database (or, if that cannot be read, the list before the batch).
    private func write(_ key: String, before: [Bookmark], _ body: @escaping (BookmarkStore) throws -> Void) {
        pendingLock.lock()
        var entry = pending[key] ?? Pending(count: 0, stars: before, base: before)
        entry.count += 1; entry.stars = bookmarks
        pending[key] = entry
        versions[key, default: 0] += 1
        pendingLock.unlock()
        let writer = self.writer
        persist { [weak self] in
            var failure: Error?
            do { try body(writer) } catch { failure = error }
            guard let self else { return }
            self.pendingLock.lock()
            var finished: Pending?
            if var entry = self.pending[key] {
                entry.count -= 1
                if failure != nil { entry.failed = true }
                if entry.count > 0 { self.pending[key] = entry } else { self.pending[key] = nil; finished = entry }
            }
            let reconcile = finished != nil && (finished!.failed || self.unreconciled.remove(key) != nil)
            self.pendingLock.unlock()
            if let failure { self.main { self.onError?(failure) } }
            if reconcile { self.reconcile(key, fallback: finished!.base) }
            if finished != nil { self.main { self.onStored?() } }
        }
    }

    /// Runs on the writer queue: read what is stored, then show it unless the viewer has
    /// edited this file since the read. Then the newer edits are shown and the check is
    /// repeated after them, so a skipped correction is never lost.
    private func reconcile(_ key: String, fallback: [Bookmark]) {
        pendingLock.lock()
        // Writes still queued behind this check would make the read stale: their own
        // batch end repeats the check once they are stored.
        if pending[key] != nil { unreconciled.insert(key); pendingLock.unlock(); return }
        let version = versions[key, default: 0]
        pendingLock.unlock()
        let stored = (try? writer.bookmarks(for: key)) ?? fallback
        main {
            self.pendingLock.lock()
            let current = self.versions[key, default: 0] == version
            let busy = self.pending[key] != nil
            if !current && busy { self.unreconciled.insert(key) }
            self.pendingLock.unlock()
            if current { if self.fileKey == key { self.publish(stored) } }
            else if !busy { self.persist { [weak self] in self?.reconcile(key, fallback: stored) } }
        }
    }

    func thumbnailURL(for b: Bookmark) -> URL? {
        thumbnailDirectory?.appendingPathComponent("\(b.id.uuidString).jpg")
    }

    // MARK: private

    private func requestThumbnail(for b: Bookmark) {
        guard let url = thumbnailURL(for: b), let path = filePath, let thumbnails else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = generation
        thumbnails.makeThumbnail(source: path, at: b.time, to: url) { [weak self] ok in
            guard let self else { return }
            // Undone or deleted while the image was being made: don't leave it behind. A
            // failing query is not "deleted": keep the picture (audit 2026-10-20). Queued
            // writes are not in the database yet, so their list is the truth meanwhile.
            self.pendingLock.lock(); let queued = self.pending[b.fileKey]?.stars; self.pendingLock.unlock()
            if let queued, !queued.contains(where: { $0.id == b.id }) {
                // Undone or deleted, but not stored yet: decide after the queued writes, so a
                // delete that fails keeps its picture and a late image is never orphaned.
                let writer = self.writer
                self.persist {
                    if (try? writer.exists(id: b.id)) == false { try? FileManager.default.removeItem(at: url) }
                }
                return
            }
            let alive: Result<Bool, Error> = queued != nil ? .success(true) : Result(catching: { try self.store.exists(id: b.id) })
            switch alive {
            case .success(false):
                try? FileManager.default.removeItem(at: url)
                return
            case .failure(let error):
                self.onError?(error)
                return
            case .success(true):
                break
            }
            // Another file is open now: its UI must not hear about this one's pictures.
            guard ok, token == self.generation, self.fileKey == b.fileKey else { return }
            self.onThumbnailReady?(b.id)
        }
    }

    private func reload() {
        guard let fileKey else { return }
        pendingLock.lock(); let queued = pending[fileKey]?.stars; pendingLock.unlock()
        if let queued { bookmarks = queued; onChange?(bookmarks); return }
        // A read error keeps the stars on screen (and reports it) rather than showing none.
        do { bookmarks = try store.bookmarks(for: fileKey) } catch { onError?(error); return }
        onChange?(bookmarks)
    }
}
