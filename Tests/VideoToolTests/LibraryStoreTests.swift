import Foundation
import Testing
@testable import VideoTool

private func dbPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).sqlite").path
}
private func rec(_ path: String, key: String = UUID().uuidString, root: String = "/m", size: Int64 = 1000,
                 modified: Double = 0, duration: Double = 60, w: Int = 1920, h: Int = 1080) -> MediaRecord {
    MediaRecord(path: path, fileKey: key, size: size, modified: Date(timeIntervalSince1970: modified),
                duration: duration, width: w, height: h, root: root)
}

@Suite struct LibraryStoreTests {
    @Test("L1 upsert then read back; a second upsert of the same path replaces it") func upsert() throws {
        let s = try LibraryStore(path: dbPath())
        try s.upsert(rec("/m/a.mp4", key: "k1", duration: 10))
        try s.upsert(rec("/m/a.mp4", key: "k1", duration: 12))
        #expect(try s.media(inRoot: nil) == [rec("/m/a.mp4", key: "k1", duration: 12)])
        #expect(try s.record(at: "/m/a.mp4")?.duration == 12)
        #expect(try s.record(at: "/m/missing.mp4") == nil)
    }

    @Test("L2 roots: add, list sorted, remove also drops that root's media only") func roots() throws {
        let s = try LibraryStore(path: dbPath())
        try s.addRoot("/m/b"); try s.addRoot("/m/a"); try s.addRoot("/m/a")
        #expect(try s.roots() == ["/m/a", "/m/b"])
        try s.upsert(rec("/m/a/1.mp4", root: "/m/a")); try s.upsert(rec("/m/b/2.mp4", root: "/m/b"))
        try s.removeRoot("/m/a")
        #expect(try s.roots() == ["/m/b"])
        #expect(try s.media(inRoot: nil).map(\.path) == ["/m/b/2.mp4"])
    }

    @Test("L3 removeMedia deletes exactly the given paths") func removeMedia() throws {
        let s = try LibraryStore(path: dbPath())
        for p in ["/m/1.mp4", "/m/2.mp4", "/m/3.mp4"] { try s.upsert(rec(p)) }
        try s.removeMedia(paths: ["/m/1.mp4", "/m/3.mp4"])
        #expect(try s.media(inRoot: nil).map(\.path) == ["/m/2.mp4"])
    }

    @Test("L4 tags are replaced per source and returned by confidence") func tags() throws {
        let s = try LibraryStore(path: dbPath())
        try s.setTags([("outdoor", 0.4), ("people", 0.9)], for: "k", source: "vision")
        #expect(try s.tags(for: "k") == ["people", "outdoor"])
        try s.setTags([("animal", 0.7)], for: "k", source: "vision")
        #expect(try s.tags(for: "k") == ["animal"])
        #expect(try s.allTags() == ["k": ["animal"]])
    }

    @Test("L5 a version-1 database (stars only) upgrades in place and keeps its stars") func migratesFromV1() throws {
        let path = dbPath()
        let star = Bookmark(id: UUID(), fileKey: "osh:1", time: 5, endTime: nil, note: "keep", createdAt: Date(timeIntervalSince1970: 1))
        try SQLiteDatabase.createVersion1ForTesting(at: path)
        try BookmarkStore(path: path).insert(star)
        let lib = try LibraryStore(path: path)
        try lib.upsert(rec("/m/a.mp4"))
        #expect(try BookmarkStore(path: path).bookmarks(for: "osh:1") == [star])
        #expect(try BookmarkStore(path: path).schemaVersion() == SQLiteDatabase.currentSchemaVersion)
    }

    @Test("L6 stars and library share one database file without stepping on each other") func shared() throws {
        let path = dbPath()
        let stars = try BookmarkStore(path: path), lib = try LibraryStore(path: path)
        try lib.upsert(rec("/m/a.mp4", key: "osh:1"))
        try stars.insert(Bookmark(id: UUID(), fileKey: "osh:1", time: 1, endTime: nil, note: "", createdAt: Date()))
        #expect(try lib.media(inRoot: nil).count == 1)
        #expect(try stars.bookmarks(for: "osh:1").count == 1)
    }

    @Test("L7 adding a folder already inside a library folder is refused; trailing slashes don't matter")
    func nestedRootRefused() throws {
        let s = try LibraryStore(path: dbPath())
        #expect(try s.addRoot("/m/movies") == .added)
        #expect(try s.addRoot("/m/movies/") == .alreadyCovered(by: "/m/movies"))
        #expect(try s.addRoot("/m/movies/trips") == .alreadyCovered(by: "/m/movies"))
        #expect(try s.roots() == ["/m/movies"])
    }

    @Test("L8 adding a parent folder absorbs its sub-folders and keeps their indexed videos")
    func parentAbsorbsChildren() throws {
        let s = try LibraryStore(path: dbPath())
        _ = try s.addRoot("/m/movies/trips"); _ = try s.addRoot("/m/movies/kids")
        try s.upsert(rec("/m/movies/trips/a.mp4", root: "/m/movies/trips"))
        #expect(try s.addRoot("/m/movies") == .absorbed(["/m/movies/kids", "/m/movies/trips"]))
        #expect(try s.roots() == ["/m/movies"])
        #expect(try s.media(inRoot: "/m/movies").map(\.path) == ["/m/movies/trips/a.mp4"])
        #expect(try s.isRoot("/m/movies") && !(try s.isRoot("/m/movies/kids")))
    }

    @Test("L9 probe status, attempts and the content check round-trip") func statusRoundTrip() throws {
        let s = try LibraryStore(path: dbPath())
        var r = rec("/m/a.mp4")
        r.status = .failed; r.attempts = 2; r.contentCheck = "chk"
        try s.upsert(r)
        #expect(try s.record(at: "/m/a.mp4") == r)
    }

    @Test("L10 two connections opening a fresh database at the same moment both succeed at the latest version")
    func concurrentOpen() async throws {
        for _ in 0..<60 {                // contention is timing-dependent: try many times
            let path = dbPath()
            async let a: Int32 = Task.detached { try LibraryStore(path: path).schemaVersion() }.value
            async let b: Int32 = Task.detached { try BookmarkStore(path: path).schemaVersion() }.value
            #expect(try await a == SQLiteDatabase.currentSchemaVersion)
            #expect(try await b == SQLiteDatabase.currentSchemaVersion)
        }
    }

    @Test("L11 orphanKeys lists tag keys no media row uses any more") func orphans() throws {
        let s = try LibraryStore(path: dbPath())
        try s.upsert(rec("/m/a.mp4", key: "k1"))
        try s.setTags([("x", 0.9)], for: "k1", source: "vision"); try s.setTags([("y", 0.9)], for: "k2", source: "vision")
        #expect(try s.orphanKeys() == ["k2"])
        try s.forget(keys: ["k2"])
        #expect(try s.allTags() == ["k1": ["x"]])
    }
}
