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
    /// Files probed at the same time (each probe is its own mpv instance).
    private let workers: Int

    static var defaultThumbnailDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoTool/LibraryThumbnails", isDirectory: true)
    }

    init(store: LibraryStore, prober: MediaProber = MPVMediaProber(), tagger: ImageTagger? = VisionTagger(),
         fingerprint: @escaping (String) -> String? = { try? FileFingerprint.compute(path: $0) },
         thumbnailDirectory: URL = LibraryIndexer.defaultThumbnailDirectory,
         workers: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
         scan: @escaping Scan = { LibraryScanner.scan(root: $0, isCancelled: $1) }) {
        self.store = store
        self.prober = prober
        self.tagger = tagger
        self.fingerprint = fingerprint
        self.thumbnailDirectory = thumbnailDirectory
        self.scan = scan
        self.workers = max(1, workers)
    }

    /// One thumbnail per content key, so copies share it. Hashed so any key is a safe file name.
    static func thumbnailURL(forKey key: String, in directory: URL = LibraryIndexer.defaultThumbnailDirectory) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).jpg")
    }

    /// What probing one piece of content produced (shared by all copies of it).
    private struct Outcome {
        var probe: MediaProbe?
        var hasThumb: Bool
        var tags: [(String, Double)]?      // nil: already tagged, or no picture
    }

    /// What phase 2 learned about one file.
    private struct Work {
        var file: ScannedFile
        var old: MediaRecord?
        var key: String?
        var check = ""
        var outcome: Outcome?
    }

    /// Phases. Stress run (tools/stress_library.sh, 2026-10-18): one file at a time took
    /// 273 s for 1000 files; this takes 31 s for 1000 and 63 s for 2000, and memory
    /// levels off at ~470 MB for both sizes (a fixed working set, not a leak).
    /// 1. classify (serial, cheap): unchanged files are skipped;
    /// 2. fingerprint + probe + tag in parallel, each file in its own autorelease pool,
    ///    each distinct content probed once;
    /// 3. write to the database serially, re-checking cancellation and that the folder
    ///    is still in the library before every write.
    func index(root: String, progress: (Progress) -> Void, isCancelled: () -> Bool) -> Summary {
        var summary = Summary()
        let stillWatched = { (try? self.store.isRoot(root)) == true }
        guard stillWatched() else { return summary }

        let result = scan(root, isCancelled)
        if isCancelled() { return summary }
        summary.unavailable = !result.complete
        let existing = Dictionary(((try? store.media(inRoot: root)) ?? []).map { ($0.path, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let total = result.files.count

        // 1. classify
        var work: [Work] = []
        for file in result.files {
            let old = existing[file.path]
            let same = old.map { $0.size == file.size && abs($0.modified.timeIntervalSince(file.modified)) < 0.001 } ?? false
            if let old, same, isSettled(old, file: file) { summary.unchanged += 1 } else { work.append(Work(file: file, old: same ? old : nil)) }
        }
        let progressLock = NSLock()
        var done = summary.unchanged
        func tick(_ current: String?) {
            progressLock.lock(); defer { progressLock.unlock() }
            done += 1
            progress(Progress(root: root, done: done, total: total, current: current))
        }
        if summary.unchanged > 0 { progressLock.lock(); progress(Progress(root: root, done: done, total: total, current: nil)); progressLock.unlock() }

        // 2. parallel fingerprint / probe / tag
        let slots = UnsafeMutableBufferPointer<Work>.allocate(capacity: work.count)
        _ = slots.initialize(from: work)
        defer { slots.deinitialize(); slots.deallocate() }
        let once = KeyedOnce<Outcome>()
        let nextLock = NSLock()
        var next = 0
        var stop = false
        DispatchQueue.concurrentPerform(iterations: min(workers, max(work.count, 1))) { _ in
            while true {
                nextLock.lock()
                if !stop && isCancelled() { stop = true }
                let i = next; next += 1
                let halted = stop
                nextLock.unlock()
                if halted || i >= slots.count { return }
                autoreleasepool {
                    var w = slots[i]
                    if !w.file.cloudOnly, let key = fingerprint(w.file.path) {
                        w.key = key
                        w.check = FileFingerprint.contentCheck(path: w.file.path) ?? ""
                        w.outcome = once.value(for: key) { self.probeAndTag(path: w.file.path, key: key) }
                    }
                    slots[i] = w
                }
                tick(slots[i].file.path)
            }
        }
        if isCancelled() || stop || !stillWatched() { return summary }   // interrupted: write nothing

        // 3. serial writes
        for w in slots {
            if isCancelled() || !stillWatched() { return summary }
            let record: MediaRecord
            if w.file.cloudOnly {
                // Listed so the user sees it, but never read: that would download it.
                record = MediaRecord(path: w.file.path, fileKey: "icloud:" + w.file.path, size: w.file.size,
                                     modified: w.file.modified, duration: 0, width: 0, height: 0, root: root,
                                     status: .cloudOnly)
            } else if let key = w.key, let outcome = w.outcome {
                let status: MediaRecord.Status = outcome.probe == nil ? .failed : (outcome.hasThumb ? .ok : .noThumbnail)
                let attempts = status == .failed ? ((w.old?.status == .failed ? w.old?.attempts : 0) ?? 0) + 1 : 0
                if status == .failed { summary.probeFailed += 1 }
                record = MediaRecord(path: w.file.path, fileKey: key, size: w.file.size, modified: w.file.modified,
                                     duration: outcome.probe?.duration ?? 0, width: outcome.probe?.width ?? 0,
                                     height: outcome.probe?.height ?? 0, root: root, status: status,
                                     attempts: attempts, contentCheck: w.check)
                if let tags = outcome.tags, (try? store.hasTags(for: key)) != true {
                    try? store.setTags(tags, for: key, source: Self.tagSource)
                }
            } else {
                summary.unreadable += 1
                continue
            }
            do { try store.upsert(record) } catch { summary.unreadable += 1; continue }
            if existing[w.file.path] == nil { summary.added += 1 } else { summary.updated += 1 }
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

    /// Probe one piece of content (thumbnail if missing) and tag it if it has no tags yet.
    /// Runs on worker threads: touches only its own thumbnail file and reads the database.
    private func probeAndTag(path: String, key: String) -> Outcome {
        let thumb = Self.thumbnailURL(forKey: key, in: thumbnailDirectory)
        let hadThumb = FileManager.default.fileExists(atPath: thumb.path)
        let probe = prober.probe(source: path, thumbnailTo: hadThumb ? nil : thumb)
        let hasThumb = FileManager.default.fileExists(atPath: thumb.path)
        var tags: [(String, Double)]?
        if let tagger, hasThumb, (try? store.hasTags(for: key)) != true {
            tags = tagger.tags(forImageAt: thumb)
        }
        return Outcome(probe: probe, hasThumb: hasThumb, tags: tags)
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

/// Computes a value once per key even when several threads ask for the same key at
/// the same time (copies of one video probed in parallel): the first caller computes,
/// the others wait for its result.
final class KeyedOnce<Value>: @unchecked Sendable {
    private final class Cell { let ready = DispatchSemaphore(value: 0); var value: Value? }
    private let lock = NSLock()
    private var cells: [String: Cell] = [:]

    func value(for key: String, compute: () -> Value) -> Value {
        lock.lock()
        if let cell = cells[key] {
            lock.unlock()
            cell.ready.wait(); cell.ready.signal()          // let any other waiter through too
            return cell.value!
        }
        let cell = Cell()
        cells[key] = cell
        lock.unlock()
        cell.value = compute()
        cell.ready.signal()
        return cell.value!
    }
}
