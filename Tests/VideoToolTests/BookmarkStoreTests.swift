import Foundation
import Testing
@testable import VideoTool

private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString).sqlite").path
}
private func bm(_ key: String, _ t: Double, note: String = "", end: Double? = nil, at created: Double = 0) -> Bookmark {
    Bookmark(id: UUID(), fileKey: key, time: t, endTime: end, note: note, createdAt: Date(timeIntervalSince1970: created))
}

@Suite struct BookmarkStoreTests {
    @Test("B1 insert then read back, sorted by time, all fields intact") func roundTrip() throws {
        let s = try BookmarkStore(path: tempDBPath())
        let a = bm("osh:1", 50, note: "第二段", at: 100), b = bm("osh:1", 10, note: "开头", end: 20, at: 200)
        try s.insert(a); try s.insert(b)
        #expect(try s.bookmarks(for: "osh:1") == [b, a])
    }

    @Test("B2 bookmarks are isolated per file key") func isolation() throws {
        let s = try BookmarkStore(path: tempDBPath())
        try s.insert(bm("osh:1", 5)); try s.insert(bm("osh:2", 6))
        #expect(try s.bookmarks(for: "osh:1").map(\.time) == [5])
        #expect(try s.bookmarks(for: "osh:3").isEmpty)
    }

    @Test("B3 update note and delete affect only that bookmark") func updateAndDelete() throws {
        let s = try BookmarkStore(path: tempDBPath())
        let a = bm("k", 1), b = bm("k", 2)
        try s.insert(a); try s.insert(b)
        try s.updateNote(id: a.id, note: "好看")
        try s.delete(id: b.id)
        let rows = try s.bookmarks(for: "k")
        #expect(rows.count == 1)
        #expect(rows.first?.note == "好看")
    }

    @Test("B4 data survives reopening the database file") func persistence() throws {
        let path = tempDBPath()
        let a = bm("k", 3.25, note: "x")
        do { let s = try BookmarkStore(path: path); try s.insert(a) }
        #expect(try BookmarkStore(path: path).bookmarks(for: "k") == [a])
    }

    @Test("B5 notes with quotes, SQL keywords, emoji and newlines are stored verbatim") func trickyText() throws {
        let s = try BookmarkStore(path: tempDBPath())
        let note = "it's \"great\"; DROP TABLE bookmarks; -- 🎬\n第二行"
        let a = bm("k'; --", 1, note: note)
        try s.insert(a)
        #expect(try s.bookmarks(for: "k'; --").first?.note == note)
    }

    @Test("B6 remembers the last path seen for a file key") func lastPath() throws {
        let s = try BookmarkStore(path: tempDBPath())
        #expect(try s.lastPath(for: "k") == nil)
        try s.rememberFile(key: "k", path: "/a/old.mp4")
        try s.rememberFile(key: "k", path: "/b/new.mp4")
        #expect(try s.lastPath(for: "k") == "/b/new.mp4")
    }

    @Test("B7 a fresh database is stamped with the current schema version") func schemaVersion() throws {
        let s = try BookmarkStore(path: tempDBPath())
        #expect(try s.schemaVersion() == BookmarkStore.currentSchemaVersion)
    }

    @Test("B8 opening a path in a missing directory creates the directory") func createsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString)/nested")
        let s = try BookmarkStore(path: dir.appendingPathComponent("library.sqlite").path)
        try s.insert(bm("k", 1))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("B9 an unopenable path throws instead of crashing") func unopenable() {
        #expect(throws: (any Error).self) { try BookmarkStore(path: "/System/forbidden-\(UUID())/x.sqlite") }
    }

    @Test("B10 exists(id:) reflects inserts and deletes") func exists() throws {
        let s = try BookmarkStore(path: tempDBPath())
        let a = bm("k", 1)
        #expect(try !s.exists(id: a.id))
        try s.insert(a); #expect(try s.exists(id: a.id))
        try s.delete(id: a.id); #expect(try !s.exists(id: a.id))
    }
}
