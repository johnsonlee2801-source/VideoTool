import Foundation

/// A starred moment. `endTime` is reserved for clipping a range later.
struct Bookmark: Equatable, Identifiable {
    var id: UUID
    var fileKey: String
    var time: Double
    var endTime: Double?
    var note: String
    var createdAt: Date
}

/// Stars, stored in the shared app database. Every statement is parameterised.
final class BookmarkStore {
    static var currentSchemaVersion: Int32 { SQLiteDatabase.currentSchemaVersion }
    static var defaultPath: String { SQLiteDatabase.defaultPath }

    private let db: SQLiteDatabase

    init(path: String = BookmarkStore.defaultPath) throws {
        db = try SQLiteDatabase(path: path)
    }

    func schemaVersion() throws -> Int32 { try db.schemaVersion() }

    // MARK: bookmarks

    func bookmarks(for fileKey: String) throws -> [Bookmark] {
        var rows: [Bookmark] = []
        try db.query("SELECT id, file_key, time, end_time, note, created_at FROM bookmarks WHERE file_key = ? ORDER BY time, created_at",
                     [.text(fileKey)]) { r in
            guard let id = UUID(uuidString: r.text(0)) else { return }
            rows.append(Bookmark(id: id, fileKey: r.text(1), time: r.double(2),
                                 endTime: r.isNull(3) ? nil : r.double(3), note: r.text(4),
                                 createdAt: Date(timeIntervalSince1970: r.double(5))))
        }
        return rows
    }

    func insert(_ b: Bookmark) throws {
        try db.run("INSERT INTO bookmarks (id, file_key, time, end_time, note, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                   [.text(b.id.uuidString), .text(b.fileKey), .real(b.time), b.endTime.map { .real($0) } ?? .null,
                    .text(b.note), .real(b.createdAt.timeIntervalSince1970)])
    }

    func updateNote(id: UUID, note: String) throws {
        try db.run("UPDATE bookmarks SET note = ? WHERE id = ?", [.text(note), .text(id.uuidString)])
    }

    func exists(id: UUID) throws -> Bool {
        var found = false
        try db.query("SELECT 1 FROM bookmarks WHERE id = ? LIMIT 1", [.text(id.uuidString)]) { _ in found = true }
        return found
    }

    func delete(id: UUID) throws {
        try db.run("DELETE FROM bookmarks WHERE id = ?", [.text(id.uuidString)])
    }

    /// Number of stars per file key (the library shows a star count per video).
    func counts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        try db.query("SELECT file_key, COUNT(*) FROM bookmarks GROUP BY file_key", []) { out[$0.text(0)] = Int($0.int(1)) }
        return out
    }

    // MARK: files

    func rememberFile(key: String, path: String) throws {
        try db.run("INSERT INTO files (file_key, last_path, seen_at) VALUES (?, ?, ?) ON CONFLICT(file_key) DO UPDATE SET last_path = excluded.last_path, seen_at = excluded.seen_at",
                   [.text(key), .text(path), .real(Date().timeIntervalSince1970)])
    }

    func lastPath(for key: String) throws -> String? {
        var path: String?
        try db.query("SELECT last_path FROM files WHERE file_key = ?", [.text(key)]) { path = $0.text(0) }
        return path
    }
}
