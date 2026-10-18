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

    private(set) var fileKey: String?
    private(set) var bookmarks: [Bookmark] = []
    private var filePath: String?
    private var identifying = false
    private var unidentifiable = false
    /// Bumped on every open/close so late fingerprint results for an older file are dropped.
    private var generation = 0
    /// Star the last ⌥←/⌥→ jumped to, and when (mpv reports the new position a little later).
    private var landed: (star: Double, at: Date)?

    var onChange: (([Bookmark]) -> Void)?
    /// A star's thumbnail finished; only the preview needs refreshing (not the list).
    var onThumbnailReady: ((UUID) -> Void)?
    var onError: ((Error) -> Void)?

    init(store: BookmarkStore, engine: PlayerEngine, now: @escaping () -> Date = Date.init,
         thumbnailDirectory: URL? = BookmarkController.defaultThumbnailDirectory,
         thumbnails: ThumbnailMaker? = MPVThumbnailMaker(),
         fingerprint: @escaping (String) -> String? = FileFingerprint.key(forTarget:),
         background: @escaping Executor = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) }) {
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

    /// Load stars for an already-identified file.
    func fileOpened(key: String, path: String) {
        fileKey = key
        filePath = path
        identifying = false
        unidentifiable = false
        landed = nil
        attempt { try store.rememberFile(key: key, path: path) }
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
            attempt { try store.delete(id: id) }
            removeThumbnail(id)
            reload()
            return .undone
        case .add:
            let b = Bookmark(id: UUID(), fileKey: fileKey, time: time, endTime: nil, note: "", createdAt: now())
            guard attempt({ try store.insert(b) }) else { return nil }
            reload()
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
            landed = (star, now())
            return BookmarkNavigator.jumpTarget(star)
        }
        landed = nil
        return time
    }

    private func land(on star: Double) {
        landed = (star, now())
        engine.seek(to: BookmarkNavigator.jumpTarget(star))
    }

    /// The star we are "at" after a jump: trusted for a moment even if mpv still
    /// reports the old position, and afterwards while the playhead is still in the
    /// stretch between the landing point and the star.
    private func landedStar(_ current: Double) -> Double? {
        guard let landed else { return nil }
        if now().timeIntervalSince(landed.at) < 1.5 { return landed.star }
        let target = BookmarkNavigator.jumpTarget(landed.star)
        if current >= target - 0.25 && current <= landed.star + BookmarkNavigator.previousGrace { return landed.star }
        return nil
    }

    // MARK: editing

    func updateNote(_ id: UUID, _ note: String) {
        attempt { try store.updateNote(id: id, note: note) }
        reload()
    }

    func delete(_ id: UUID) {
        attempt { try store.delete(id: id) }
        removeThumbnail(id)
        reload()
    }

    func thumbnailURL(for b: Bookmark) -> URL? {
        thumbnailDirectory?.appendingPathComponent("\(b.id.uuidString).jpg")
    }

    // MARK: private

    private func requestThumbnail(for b: Bookmark) {
        guard let url = thumbnailURL(for: b), let path = filePath, let thumbnails else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        thumbnails.makeThumbnail(source: path, at: b.time, to: url) { [weak self] ok in
            guard let self else { return }
            // Undone or deleted while the image was being made: don't leave it behind.
            if (try? self.store.exists(id: b.id)) != true {
                try? FileManager.default.removeItem(at: url)
                return
            }
            if ok { self.onThumbnailReady?(b.id) }
        }
    }

    private func reload() {
        guard let fileKey else { return }
        bookmarks = (try? store.bookmarks(for: fileKey)) ?? []
        onChange?(bookmarks)
    }

    private func removeThumbnail(_ id: UUID) {
        guard let dir = thumbnailDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).jpg"))
    }

    @discardableResult
    private func attempt(_ body: () throws -> Void) -> Bool {
        do { try body(); return true } catch { onError?(error); return false }
    }
}
