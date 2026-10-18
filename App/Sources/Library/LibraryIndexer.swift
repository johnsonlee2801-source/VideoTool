import CryptoKit
import Foundation

/// Brings the library index in line with what is on disk under one folder.
/// Only reads user files; writes go to the app's database and thumbnail folder.
/// Synchronous: run it on a background queue.
///
/// Safety rules (from the step 4 review):
/// - Records are removed only after a *complete* walk of an existing root, so an
///   unplugged drive or an unreadable sub-folder never empties the index.
/// - If the folder stops being a library folder mid-pass, the pass stops.
/// - iCloud placeholders are listed but never read (reading forces a download).
final class LibraryIndexer {
    struct Progress: Equatable {
        var root: String
        var done: Int
        var total: Int
        var current: String?
    }

    struct Summary: Equatable {
        var added = 0, updated = 0, unchanged = 0, removed = 0
        /// Files that could not be read at all (not listed).
        var unreadable = 0
        /// Files listed, but whose duration/size/thumbnail could not be read.
        var probeFailed = 0
        /// The folder was missing or only partly readable; nothing was removed.
        var unavailable = false
    }

    static let tagSource = "vision"
    /// A failing probe is retried on this many scans, then left until the file changes.
    static let maxProbeAttempts = 3

    typealias Scan = (_ root: String, _ isCancelled: () -> Bool) -> ScanResult

    private let store: LibraryStore
    private let prober: MediaProber
    private let tagger: ImageTagger?
    private let fingerprint: (String) -> String?
    private let thumbnailDirectory: URL
    private let scan: Scan

    static var defaultThumbnailDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoTool/LibraryThumbnails", isDirectory: true)
    }

    init(store: LibraryStore, prober: MediaProber = MPVMediaProber(), tagger: ImageTagger? = VisionTagger(),
         fingerprint: @escaping (String) -> String? = { try? FileFingerprint.compute(path: $0) },
         thumbnailDirectory: URL = LibraryIndexer.defaultThumbnailDirectory,
         scan: @escaping Scan = { LibraryScanner.scan(root: $0, isCancelled: $1) }) {
        self.store = store
        self.prober = prober
        self.tagger = tagger
        self.fingerprint = fingerprint
        self.thumbnailDirectory = thumbnailDirectory
        self.scan = scan
    }

    /// One thumbnail per content key, so copies share it. Hashed so any key is a safe file name.
    static func thumbnailURL(forKey key: String, in directory: URL = LibraryIndexer.defaultThumbnailDirectory) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).jpg")
    }

    func index(root: String, progress: (Progress) -> Void, isCancelled: () -> Bool) -> Summary {
        var summary = Summary()
        // Stop as soon as the folder is no longer part of the library (removed by the user).
        let stillWatched = { (try? self.store.isRoot(root)) == true }
        guard stillWatched() else { return summary }

        let result = scan(root, isCancelled)
        if isCancelled() { return summary }
        summary.unavailable = !result.complete
        let existing = Dictionary(((try? store.media(inRoot: root)) ?? []).map { ($0.path, $0) },
                                  uniquingKeysWith: { a, _ in a })
        var taggedKeys = Set<String>()

        for (i, file) in result.files.enumerated() {
            if isCancelled() || !stillWatched() { return summary }   // interrupted: remove nothing
            progress(Progress(root: root, done: i, total: result.files.count, current: file.path))
            defer { progress(Progress(root: root, done: i + 1, total: result.files.count, current: nil)) }

            let old = existing[file.path]
            let same = old.map { $0.size == file.size && abs($0.modified.timeIntervalSince(file.modified)) < 0.001 } ?? false
            if let old, same, isSettled(old, file: file) {
                summary.unchanged += 1
                continue
            }

            var record: MediaRecord
            if file.cloudOnly {
                // Listed so the user sees it, but never read: that would download it.
                record = MediaRecord(path: file.path, fileKey: "icloud:" + file.path, size: file.size,
                                     modified: file.modified, duration: 0, width: 0, height: 0, root: root,
                                     status: .cloudOnly)
            } else {
                guard let key = fingerprint(file.path) else { summary.unreadable += 1; continue }
                let thumb = Self.thumbnailURL(forKey: key, in: thumbnailDirectory)
                let hadThumb = FileManager.default.fileExists(atPath: thumb.path)
                let probe = prober.probe(source: file.path, thumbnailTo: hadThumb ? nil : thumb)
                let hasThumb = FileManager.default.fileExists(atPath: thumb.path)
                let status: MediaRecord.Status = probe == nil ? .failed : (hasThumb ? .ok : .noThumbnail)
                let attempts = status == .failed ? ((same && old?.status == .failed) ? (old?.attempts ?? 0) : 0) + 1 : 0
                if status == .failed { summary.probeFailed += 1 }
                record = MediaRecord(path: file.path, fileKey: key, size: file.size, modified: file.modified,
                                     duration: probe?.duration ?? 0, width: probe?.width ?? 0, height: probe?.height ?? 0,
                                     root: root, status: status, attempts: attempts,
                                     contentCheck: FileFingerprint.contentCheck(path: file.path) ?? "")
                if let tagger, hasThumb, !taggedKeys.contains(key), (try? store.hasTags(for: key)) != true {
                    try? store.setTags(tagger.tags(forImageAt: thumb), for: key, source: Self.tagSource)
                    taggedKeys.insert(key)
                }
            }

            guard stillWatched() else { return summary }
            do { try store.upsert(record) } catch { summary.unreadable += 1; continue }
            if old == nil { summary.added += 1 } else { summary.updated += 1 }
        }

        // Only a complete walk of a reachable folder may conclude that files are gone.
        guard result.complete, !isCancelled(), stillWatched() else { return summary }
        let present = Set(result.files.map(\.path))
        let gone = existing.values.filter { !present.contains($0.path) }
        if !gone.isEmpty, (try? store.removeMedia(paths: gone.map(\.path))) != nil {
            summary.removed = gone.count
            cleanUpOrphans()
        }
        return summary
    }

    /// Whether an unchanged file (same size and date) needs no work this pass.
    private func isSettled(_ old: MediaRecord, file: ScannedFile) -> Bool {
        switch old.status {
        case .ok:
            return FileManager.default.fileExists(atPath: Self.thumbnailURL(forKey: old.fileKey, in: thumbnailDirectory).path)
        case .noThumbnail:
            return true
        case .failed:
            return old.attempts >= Self.maxProbeAttempts
        case .cloudOnly:
            return file.cloudOnly          // downloaded since: index it now
        }
    }

    /// Tags and thumbnails of content no video in the library has any more.
    private func cleanUpOrphans() {
        guard let keys = try? store.orphanKeys(), !keys.isEmpty else { return }
        try? store.forget(keys: keys)
        for key in keys { try? FileManager.default.removeItem(at: Self.thumbnailURL(forKey: key, in: thumbnailDirectory)) }
    }
}
