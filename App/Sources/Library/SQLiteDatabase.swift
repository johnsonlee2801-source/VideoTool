import Foundation
import SQLite3

/// One SQLite connection plus the app's schema migrations. Stars and the
/// library both use `~/Library/Application Support/VideoTool/library.sqlite`;
/// each store opens its own connection, and every open migrates to the latest
/// schema, so the order in which stores open never matters.
final class SQLiteDatabase {
    static let currentSchemaVersion: Int32 = 4

    enum Failure: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String { if case .sqlite(let m) = self { return m }; return "" }
    }

    enum Value { case text(String), real(Double), int(Int64), null }

    /// Read-only view of the current result row.
    struct Row {
        fileprivate let stmt: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }

    static var defaultPath: String {
        AppData.directory.appendingPathComponent("library.sqlite").path
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try open(path)
        // busy_timeout first: another connection may be opening/migrating the same file right now.
        try exec("PRAGMA busy_timeout = \(Int(min(Self.lockWait, 5) * 1000));")
        // Switching to WAL and migrating need an exclusive lock; under contention SQLite can
        // return "database is locked" at once instead of waiting (test L10). Retry briefly.
        try Self.retryingWhileLocked { try exec("PRAGMA journal_mode = WAL;") }
        try Self.retryingWhileLocked { try migrate() }
    }

    /// Longest wait for another connection's lock when opening (busy timeout and retries
    /// together). Forty retries each waiting out a 5 s busy timeout could block for
    /// over three minutes (audit 2026-10-20). Tests shorten it.
    static var lockWait: TimeInterval = 10

    private static func retryingWhileLocked(_ body: () throws -> Void) throws {
        var attempt = 0
        let deadline = Date().addingTimeInterval(lockWait)
        while true {
            do { return try body() } catch Failure.sqlite(let message)
                where Date() < deadline && (message.contains("locked") || message.contains("busy")) {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.025 * Double(min(attempt, 8)))
            }
        }
    }

    private init(rawPath path: String) throws {
        try open(path)
    }

    private func open(_ path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil                       // deinit must not close it a second time
            throw Failure.sqlite(message)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: migrations

    private static let version1 = """
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
        """

    private static let version2 = """
        CREATE TABLE IF NOT EXISTS library_roots (
            path TEXT PRIMARY KEY,
            added_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS media (
            path TEXT PRIMARY KEY,
            file_key TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            duration REAL NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            root TEXT NOT NULL,
            scanned_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS media_key ON media(file_key);
        CREATE INDEX IF NOT EXISTS media_root ON media(root);
        CREATE TABLE IF NOT EXISTS tags (
            file_key TEXT NOT NULL,
            tag TEXT NOT NULL,
            confidence REAL NOT NULL,
            source TEXT NOT NULL,
            PRIMARY KEY (file_key, tag)
        );
        PRAGMA user_version = 2;
        """

    /// Probe bookkeeping (retry failed probes, don't re-probe files with no picture,
    /// leave iCloud-only files alone) and a content check that confirms duplicates.
    private static let version3 = """
        ALTER TABLE media ADD COLUMN status TEXT NOT NULL DEFAULT 'ok';
        ALTER TABLE media ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE media ADD COLUMN content_check TEXT NOT NULL DEFAULT '';
        PRAGMA user_version = 3;
        """

    /// Library folders can be "this layer only" (broad folders such as Downloads).
    private static let version4 = """
        ALTER TABLE library_roots ADD COLUMN recursive INTEGER NOT NULL DEFAULT 1;
        PRAGMA user_version = 4;
        """

    private func migrate() throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try schemaVersion()
            if v < 1 { try exec(Self.version1) }
            if v < 2 { try exec(Self.version2) }
            if v < 3 { try exec(Self.version3) }
            if v < 4 { try exec(Self.version4) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func schemaVersion() throws -> Int32 {
        var version: Int32 = 0
        try query("PRAGMA user_version", []) { version = Int32($0.int(0)) }
        return version
    }

    /// Writes a database exactly as version 1 of the app did (tests the upgrade path).
    static func createVersion1ForTesting(at path: String) throws {
        let raw = try SQLiteDatabase(rawPath: path)
        try raw.exec(version1)
    }

    // MARK: statements

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw Failure.sqlite(message)
        }
    }

    func run(_ sql: String, _ values: [Value]) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    func query(_ sql: String, _ values: [Value], row: (Row) -> Void) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(Row(stmt: stmt)); continue }
            if rc == SQLITE_DONE { return }
            throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Runs `body` in one transaction (fast bulk writes during a scan).
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
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
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}
