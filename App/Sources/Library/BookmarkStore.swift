import Foundation
import SQLite3

/// A starred moment. `endTime` is reserved for clipping a range later.
struct Bookmark: Equatable, Identifiable {
    var id: UUID
    var fileKey: String
    var time: Double
    var endTime: Double?
    var note: String
    var createdAt: Date
}

/// SQLite-backed storage for stars (and, in step 4, the library). One
/// connection, used from the main thread; every statement is parameterised.
final class BookmarkStore {
    static let currentSchemaVersion: Int32 = 1

    enum Failure: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String { if case .sqlite(let m) = self { return m }; return "" }
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoTool/library.sqlite").path
    }

    init(path: String = BookmarkStore.defaultPath) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil                       // deinit must not close it a second time
            throw Failure.sqlite(message)
        }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: schema

    private func migrate() throws {
        if try schemaVersion() < 1 {
            try exec("""
                CREATE TABLE IF NOT EXISTS bookmarks (
                    id TEXT PRIMARY KEY,
                    file_key TEXT NOT NULL,
                    time REAL NOT NULL,
                    end_time REAL,
                    note TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS bookmarks_file ON bookmarks(file_key, time);
                CREATE TABLE IF NOT EXISTS files (
                    file_key TEXT PRIMARY KEY,
                    last_path TEXT NOT NULL,
                    seen_at REAL NOT NULL
                );
                PRAGMA user_version = 1;
                """)
        }
    }

    func schemaVersion() throws -> Int32 {
        var version: Int32 = 0
        try query("PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
        return version
    }

    // MARK: bookmarks

    func bookmarks(for fileKey: String) throws -> [Bookmark] {
        var rows: [Bookmark] = []
        try query("SELECT id, file_key, time, end_time, note, created_at FROM bookmarks WHERE file_key = ? ORDER BY time, created_at",
                  [.text(fileKey)]) { s in
            guard let id = UUID(uuidString: Self.text(s, 0)) else { return }
            rows.append(Bookmark(id: id, fileKey: Self.text(s, 1), time: sqlite3_column_double(s, 2),
                                 endTime: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : sqlite3_column_double(s, 3),
                                 note: Self.text(s, 4),
                                 createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 5))))
        }
        return rows
    }

    func insert(_ b: Bookmark) throws {
        try run("INSERT INTO bookmarks (id, file_key, time, end_time, note, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(b.id.uuidString), .text(b.fileKey), .real(b.time), b.endTime.map(Value.real) ?? .null,
                 .text(b.note), .real(b.createdAt.timeIntervalSince1970)])
    }

    func updateNote(id: UUID, note: String) throws {
        try run("UPDATE bookmarks SET note = ? WHERE id = ?", [.text(note), .text(id.uuidString)])
    }

    func exists(id: UUID) throws -> Bool {
        var found = false
        try query("SELECT 1 FROM bookmarks WHERE id = ? LIMIT 1", [.text(id.uuidString)]) { _ in found = true }
        return found
    }

    func delete(id: UUID) throws {
        try run("DELETE FROM bookmarks WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: files

    func rememberFile(key: String, path: String) throws {
        try run("INSERT INTO files (file_key, last_path, seen_at) VALUES (?, ?, ?) ON CONFLICT(file_key) DO UPDATE SET last_path = excluded.last_path, seen_at = excluded.seen_at",
                [.text(key), .text(path), .real(Date().timeIntervalSince1970)])
    }

    func lastPath(for key: String) throws -> String? {
        var path: String?
        try query("SELECT last_path FROM files WHERE file_key = ?", [.text(key)]) { path = Self.text($0, 0) }
        return path
    }

    // MARK: sqlite plumbing

    private enum Value { case text(String), real(Double), null }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw Failure.sqlite(message)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func query(_ sql: String, _ values: [Value], row: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func text(_ s: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
    }
}
