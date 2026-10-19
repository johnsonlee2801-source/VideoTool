import Foundation

/// A video found in a library folder. `fileKey` is the content fingerprint, so
/// two records with the same key are duplicates.
struct MediaRecord: Equatable {
    enum Status: String {
        case ok                  // probed, thumbnail present
        case noThumbnail         // probed, but no picture could be rendered (do not re-probe)
        case failed              // probe failed; retried a few times
        case cloudOnly           // iCloud placeholder; never read until downloaded
    }

    var path: String
    var fileKey: String
    var size: Int64
    var modified: Date
    var duration: Double
    var width: Int
    var height: Int
    var root: String
    var status: Status = .ok
    var attempts = 0
    /// Confirms duplicates beyond the OSHash (see FileFingerprint.contentCheck).
    var contentCheck = ""
}

/// A library folder. `recursive` false: only the videos directly in it ("this layer only").
struct LibraryRoot: Equatable {
    var path: String
    var recursive: Bool

    /// Whether `folder` is this library folder or, for a whole folder, inside it.
    func covers(_ folder: String) -> Bool {
        folder == path || (recursive && folder.hasPrefix(path == "/" ? "/" : path + "/"))
    }
}

enum AddRootResult: Equatable {
    case added
    /// Already inside (or equal to) a library folder; nothing changed.
    case alreadyCovered(by: String)
    /// Added; these former library folders inside it were merged into it.
    case absorbed([String])
}

/// The library index: watched folders, the videos in them, and their tags.
/// It records what is on disk; it never moves, renames or deletes user files.
final class LibraryStore {
    private let db: SQLiteDatabase

    init(path: String = SQLiteDatabase.defaultPath) throws {
        db = try SQLiteDatabase(path: path)
    }

    // MARK: roots

    static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Adds a folder. A folder already covered by a library folder is refused (its
    /// videos are already indexed). A whole folder absorbs library folders inside it,
    /// keeping their rows, and upgrades itself if it was "this layer only".
    /// A "this layer only" folder absorbs nothing: its sub-folders stay separate.
    @discardableResult
    func addRoot(_ path: String, recursive: Bool = true) throws -> AddRootResult {
        let new = Self.normalized(path)
        let existing = try rootEntries()
        if let same = existing.first(where: { $0.path == new }), same.recursive || !recursive {
            return .alreadyCovered(by: same.path)
        }
        if let parent = existing.first(where: { $0.path != new && $0.covers(new) }) {
            return .alreadyCovered(by: parent.path)
        }
        let inside = new == "/" ? "/" : new + "/"
        let children = recursive ? existing.map(\.path).filter { $0 != new && $0.hasPrefix(inside) } : []
        try db.transaction {
            try db.run("""
                INSERT INTO library_roots (path, added_at, recursive) VALUES (?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET recursive = excluded.recursive
                """, [.text(new), .real(Date().timeIntervalSince1970), .int(recursive ? 1 : 0)])
            for child in children {
                try db.run("UPDATE media SET root = ? WHERE root = ?", [.text(new), .text(child)])
                try db.run("DELETE FROM library_roots WHERE path = ?", [.text(child)])
            }
        }
        return children.isEmpty ? .added : .absorbed(children)
    }

    func isRoot(_ path: String) throws -> Bool {
        var found = false
        try db.query("SELECT 1 FROM library_roots WHERE path = ? LIMIT 1", [.text(path)]) { _ in found = true }
        return found
    }

    func schemaVersion() throws -> Int32 { try db.schemaVersion() }

    func roots() throws -> [String] { try rootEntries().map(\.path) }

    func rootEntries() throws -> [LibraryRoot] {
        var out: [LibraryRoot] = []
        try db.query("SELECT path, recursive FROM library_roots ORDER BY path", []) {
            out.append(LibraryRoot(path: $0.text(0), recursive: $0.int(1) != 0))
        }
        return out
    }

    /// false only for a "this layer only" folder (unknown folders count as whole).
    func isRecursive(_ root: String) throws -> Bool {
        var recursive = true
        try db.query("SELECT recursive FROM library_roots WHERE path = ?", [.text(root)]) { recursive = $0.int(0) != 0 }
        return recursive
    }

    /// Stops watching a folder and forgets its videos (the files themselves are untouched).
    func removeRoot(_ path: String) throws {
        try db.transaction {
            try db.run("DELETE FROM media WHERE root = ?", [.text(path)])
            try db.run("DELETE FROM library_roots WHERE path = ?", [.text(path)])
        }
    }

    // MARK: media

    func upsert(_ r: MediaRecord) throws {
        try db.run("""
            INSERT INTO media (path, file_key, size, mtime, duration, width, height, root, scanned_at,
                               status, attempts, content_check)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET file_key = excluded.file_key, size = excluded.size,
                mtime = excluded.mtime, duration = excluded.duration, width = excluded.width,
                height = excluded.height, root = excluded.root, scanned_at = excluded.scanned_at,
                status = excluded.status, attempts = excluded.attempts, content_check = excluded.content_check
            """, [.text(r.path), .text(r.fileKey), .int(r.size), .real(r.modified.timeIntervalSince1970),
                  .real(r.duration), .int(Int64(r.width)), .int(Int64(r.height)), .text(r.root),
                  .real(Date().timeIntervalSince1970), .text(r.status.rawValue), .int(Int64(r.attempts)),
                  .text(r.contentCheck)])
    }

    func record(at path: String) throws -> MediaRecord? {
        try fetch("WHERE path = ?", [.text(path)]).first
    }

    func media(inRoot root: String?) throws -> [MediaRecord] {
        if let root { return try fetch("WHERE root = ? ORDER BY path", [.text(root)]) }
        return try fetch("ORDER BY path", [])
    }

    func removeMedia(paths: [String]) throws {
        try db.transaction {
            for p in paths { try db.run("DELETE FROM media WHERE path = ?", [.text(p)]) }
        }
    }

    private func fetch(_ clause: String, _ values: [SQLiteDatabase.Value]) throws -> [MediaRecord] {
        var out: [MediaRecord] = []
        try db.query("SELECT path, file_key, size, mtime, duration, width, height, root, status, attempts, content_check FROM media \(clause)", values) { r in
            out.append(MediaRecord(path: r.text(0), fileKey: r.text(1), size: r.int(2),
                                   modified: Date(timeIntervalSince1970: r.double(3)), duration: r.double(4),
                                   width: Int(r.int(5)), height: Int(r.int(6)), root: r.text(7),
                                   status: MediaRecord.Status(rawValue: r.text(8)) ?? .ok,
                                   attempts: Int(r.int(9)), contentCheck: r.text(10)))
        }
        return out
    }

    // MARK: tags

    /// Replaces all tags from `source` for this content key.
    func setTags(_ tags: [(String, Double)], for key: String, source: String) throws {
        try db.transaction {
            try db.run("DELETE FROM tags WHERE file_key = ? AND source = ?", [.text(key), .text(source)])
            for (tag, confidence) in tags {
                try db.run("INSERT OR REPLACE INTO tags (file_key, tag, confidence, source) VALUES (?, ?, ?, ?)",
                           [.text(key), .text(tag), .real(confidence), .text(source)])
            }
        }
    }

    func tags(for key: String) throws -> [String] {
        var out: [String] = []
        try db.query("SELECT tag FROM tags WHERE file_key = ? ORDER BY confidence DESC, tag", [.text(key)]) { out.append($0.text(0)) }
        return out
    }

    func allTags() throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        try db.query("SELECT file_key, tag FROM tags ORDER BY file_key, confidence DESC, tag", []) {
            out[$0.text(0), default: []].append($0.text(1))
        }
        return out
    }

    /// Content keys that still have tags but no longer belong to any video.
    func orphanKeys() throws -> [String] {
        var out: [String] = []
        try db.query("SELECT DISTINCT file_key FROM tags WHERE file_key NOT IN (SELECT file_key FROM media) ORDER BY file_key", []) {
            out.append($0.text(0))
        }
        return out
    }

    func forget(keys: [String]) throws {
        try db.transaction {
            for k in keys { try db.run("DELETE FROM tags WHERE file_key = ?", [.text(k)]) }
        }
    }

    func hasTags(for key: String) throws -> Bool {
        var found = false
        try db.query("SELECT 1 FROM tags WHERE file_key = ? LIMIT 1", [.text(key)]) { _ in found = true }
        return found
    }
}
