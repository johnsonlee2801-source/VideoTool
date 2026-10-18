import Foundation
import SQLite3
import Testing
@testable import VideoTool

// "This layer only" library folders (2026-10-18): a broad folder such as Downloads
// is indexed without its sub-folders, so opening a video there can still offer it.

private func dbPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("shallow-\(UUID().uuidString).sqlite").path
}

@Suite struct LibraryShallowRootStoreTests {
    @Test("SR1 a folder can be added as 'this layer only'; the flag round-trips") func flag() throws {
        let s = try LibraryStore(path: dbPath())
        #expect(try s.addRoot("/h/Downloads", recursive: false) == .added)
        #expect(try s.addRoot("/m/movies") == .added)
        #expect(try s.rootEntries() == [LibraryRoot(path: "/h/Downloads", recursive: false),
                                        LibraryRoot(path: "/m/movies", recursive: true)])
        #expect(try !s.isRecursive("/h/Downloads"))
        #expect(try s.isRecursive("/m/movies"))
        #expect(try s.roots() == ["/h/Downloads", "/m/movies"])
    }

    @Test("SR2 a this-layer-only folder does not cover its sub-folders, which can be added on their own")
    func shallowDoesNotCover() throws {
        let s = try LibraryStore(path: dbPath())
        _ = try s.addRoot("/h/Downloads", recursive: false)
        #expect(try s.addRoot("/h/Downloads", recursive: false) == .alreadyCovered(by: "/h/Downloads"))
        #expect(try s.addRoot("/h/Downloads/美剧") == .added)
        #expect(try s.roots() == ["/h/Downloads", "/h/Downloads/美剧"], "a shallow folder absorbs nothing")
        #expect(try s.addRoot("/h/Downloads/美剧/S2", recursive: false) == .alreadyCovered(by: "/h/Downloads/美剧"))
    }

    @Test("SR3 adding a this-layer-only folder later as a whole folder upgrades it and absorbs sub-folders")
    func upgrade() throws {
        let s = try LibraryStore(path: dbPath())
        _ = try s.addRoot("/h/Downloads", recursive: false)
        _ = try s.addRoot("/h/Downloads/美剧")
        #expect(try s.addRoot("/h/Downloads") == .absorbed(["/h/Downloads/美剧"]))
        #expect(try s.rootEntries() == [LibraryRoot(path: "/h/Downloads", recursive: true)])
    }

    @Test("SR4 adding a this-layer-only folder never takes over a whole folder already there")
    func shallowUnderDeep() throws {
        let s = try LibraryStore(path: dbPath())
        _ = try s.addRoot("/h/Downloads")
        #expect(try s.addRoot("/h/Downloads", recursive: false) == .alreadyCovered(by: "/h/Downloads"))
        #expect(try s.isRecursive("/h/Downloads"))
    }

    @Test("SR5 upgrading a version-3 database keeps existing folders as whole folders") func migrates() throws {
        let path = dbPath()
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        // The version-3 shape of library_roots (no "recursive" column) with one folder in it.
        #expect(sqlite3_exec(db, """
            CREATE TABLE library_roots (path TEXT PRIMARY KEY, added_at REAL NOT NULL);
            INSERT INTO library_roots VALUES ('/m/old', 0);
            PRAGMA user_version = 3;
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let s = try LibraryStore(path: path)
        #expect(try s.schemaVersion() == SQLiteDatabase.currentSchemaVersion)
        #expect(try s.isRecursive("/m/old"))
    }
}

@Suite struct LibraryShallowScanTests {
    @Test("SR6 the scanner can stay in the top layer") func topLayerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr6-\(UUID().uuidString)")
        for rel in ["a.mp4", "b.mkv", "sub/c.mp4", "sub/deep/d.mov"] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 10).write(to: url)
        }
        let r = root.resolvingSymlinksInPath().path
        let shallow = LibraryScanner.scan(root: r, recursive: false)
        #expect(shallow.files.map { ($0.path as NSString).lastPathComponent } == ["a.mp4", "b.mkv"])
        #expect(shallow.complete)
        #expect(LibraryScanner.scan(root: r).files.count == 4)
    }

    @Test("SR7 indexing a this-layer-only folder lists only its own videos") func indexerUsesFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr7-\(UUID().uuidString)")
        for (rel, seed) in [("a.mp4", 1), ("sub/b.mp4", 2)] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<2000).map { UInt8(($0 + seed) % 256) }).write(to: url)
        }
        let r = root.resolvingSymlinksInPath().path
        let store = try LibraryStore(path: dbPath())
        _ = try store.addRoot(r, recursive: false)
        let indexer = LibraryIndexer(store: store, prober: FakeProber(), tagger: nil,
                                     thumbnailDirectory: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("sr7thumbs-\(UUID().uuidString)"))
        _ = indexer.index(root: r, progress: { _ in }, isCancelled: { false })
        #expect(try store.media(inRoot: r).map { ($0.path as NSString).lastPathComponent } == ["a.mp4"])
    }
}
