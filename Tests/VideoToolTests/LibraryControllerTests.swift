import Foundation
import Testing
@testable import VideoTool

@MainActor
private final class Rig {
    let root: String
    let store: LibraryStore
    let stars: BookmarkStore
    let prober = FakeProber()
    let tagger = FakeTagger()
    let background = ManualQueue()
    let main = ManualQueue()
    let thumbs = TestTemp.directory.appendingPathComponent("lcthumbs-\(UUID().uuidString)")
    lazy var controller = LibraryController(
        store: store, stars: stars,
        makeIndexer: { [unowned self] in
            LibraryIndexer(store: self.store, prober: self.prober, tagger: self.tagger,
                           fingerprint: { try? FileFingerprint.compute(path: $0) }, thumbnailDirectory: self.thumbs)
        },
        thumbnailDirectory: thumbs,
        background: { [unowned self] in self.background.submit($0) },
        main: { [unowned self] in self.main.submit($0) })

    init() throws {
        root = URL(fileURLWithPath: TestTemp.directory.appendingPathComponent("lc-\(UUID().uuidString)").path)
            .resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let db = TestTemp.directory.appendingPathComponent("lc-\(UUID().uuidString).sqlite").path
        store = try LibraryStore(path: db)
        stars = try BookmarkStore(path: db)
    }
    @discardableResult func file(_ rel: String, seed: UInt8) throws -> String {
        let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<1000).map { UInt8((Int($0) &+ Int(seed)) % 256) }).write(to: url)
        return url.path
    }
    func settle() { while !(background.jobs.isEmpty && main.jobs.isEmpty) { background.runAll(); main.runAll() } }
}

@Suite @MainActor struct LibraryControllerTests {
    @Test("LC1 adding a folder indexes it in the background and then shows its videos") func addFolder() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1); try r.file("trip/b.mkv", seed: 2)
        var changes = 0
        r.controller.onChange = { changes += 1 }
        r.controller.addRoot(r.root)
        #expect(r.controller.isIndexing)
        #expect(r.controller.items.isEmpty, "nothing shown until the background pass finishes")
        r.settle()
        #expect(!r.controller.isIndexing)
        #expect(r.controller.roots == [r.root])
        #expect(r.controller.items.map(\.name).sorted() == ["a.mp4", "b.mkv"])
        #expect(r.controller.items.allSatisfy { $0.tags == ["户外"] })
        #expect(changes >= 2)
        #expect(r.controller.lastSummary?.added == 2)
    }

    @Test("LC2 grouping mode and search drive the sections") func sections() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1); try r.file("trip/b.mkv", seed: 2)
        r.controller.addRoot(r.root); r.settle()
        r.controller.mode = .folder
        #expect(r.controller.sections.map(\.title) == ["（根目录）", "trip"])
        r.controller.search = "b.m"
        #expect(r.controller.sections.flatMap(\.items).map(\.name) == ["b.mkv"])
    }

    @Test("LC3 rescanning picks up new files and drops deleted ones") func rescan() throws {
        let r = try Rig()
        let a = try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root); r.settle()
        try FileManager.default.removeItem(atPath: a)
        try r.file("new.mp4", seed: 3)
        r.controller.rescanAll(); r.settle()
        #expect(r.controller.items.map(\.name) == ["new.mp4"])
    }

    @Test("LC4 removing a folder forgets its videos but leaves the files on disk") func removeFolder() throws {
        let r = try Rig()
        let a = try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root); r.settle()
        r.controller.removeRoot(r.root)
        #expect(r.controller.roots.isEmpty && r.controller.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test("LC5 a second scan request while one is running is queued and really runs afterwards") func serialScans() throws {
        let r = try Rig()
        let a = try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root)
        r.controller.rescanAll()
        #expect(r.background.jobs.count == 1, "only one scan in flight")
        r.background.runAll()                         // first pass runs, its result not yet delivered
        try FileManager.default.removeItem(atPath: a)
        r.settle()                                    // delivers it, then runs the queued pass
        #expect(r.controller.items.isEmpty, "the queued pass saw the deletion")
        #expect(r.controller.lastSummary?.removed == 1)
    }

    @Test("LC9 removing a folder while its scan is running really removes it") func removeDuringScan() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root)
        r.controller.removeRoot(r.root)
        r.settle()
        #expect(r.controller.roots.isEmpty)
        #expect(r.controller.items.isEmpty)
    }

    @Test("LC10 progress updates the status only; the grid is reloaded once the pass ends") func progressIsLight() throws {
        let r = try Rig()
        for i in 0..<5 { try r.file("v\(i).mp4", seed: UInt8(i)) }
        var full = 0, light = 0
        r.controller.onChange = { full += 1 }
        r.controller.onProgress = { light += 1 }
        r.controller.addRoot(r.root)
        let before = full
        r.settle()
        #expect(light >= 1)
        #expect(full - before == 1, "one reload at the end, not one per file")
    }

    @Test("LC11 cancelling stops the batch: the second folder is not scanned and nothing is removed") func cancelBatch() throws {
        let r = try Rig()
        try r.file("one/a.mp4", seed: 1)
        let second = r.root + "/../" + (r.root as NSString).lastPathComponent + "-second"
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: second + "/b.mp4"))
        r.controller.addRoot(r.root + "/one"); r.controller.addRoot(second)
        r.controller.cancelScan()
        r.settle()
        #expect(!r.controller.isIndexing)
        #expect(!r.prober.calls.contains("b.mp4"))
    }

    @Test("LC12 adding a folder inside a library folder explains why nothing changed") func nestedFolderMessage() throws {
        let r = try Rig()
        try r.file("sub/a.mp4", seed: 1)
        r.controller.addRoot(r.root); r.settle()
        r.controller.addRoot(r.root + "/sub")
        #expect(r.controller.roots == [r.root])
        #expect(r.controller.notice?.contains("已在视频库") == true)
    }

    @Test("LC13 if the indexer cannot be created (database busy), the scan fails visibly instead of sharing a connection")
    func indexerUnavailable() throws {
        let r = try Rig()
        let c = LibraryController(store: r.store, stars: nil, makeIndexer: { nil }, thumbnailDirectory: r.thumbs,
                                  background: { r.background.submit($0) }, main: { r.main.submit($0) })
        c.addRoot(r.root); r.settle()
        #expect(!c.isIndexing)
        #expect(c.notice?.contains("无法") == true)
    }

    @Test("LC6 each video shows how many stars it has") func starCounts() throws {
        let r = try Rig()
        let a = try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root); r.settle()
        let key = try #require(try r.store.record(at: a)?.fileKey)
        for t in [1.0, 2.0] {
            try r.stars.insert(Bookmark(id: UUID(), fileKey: key, time: t, endTime: nil, note: "", createdAt: Date()))
        }
        r.controller.reload()
        #expect(r.controller.items.first?.starCount == 2)
    }

    @Test("LC7 progress text while scanning; summary text afterwards") func statusText() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root)
        #expect(r.controller.statusText.hasPrefix("正在扫描"))
        r.settle()
        #expect(r.controller.statusText == "共 1 个视频 · 新增 1")
        try FileManager.default.moveItem(atPath: r.root, toPath: r.root + "-away")
        defer { try? FileManager.default.moveItem(atPath: r.root + "-away", toPath: r.root) }
        r.controller.rescanAll(); r.settle()
        #expect(r.controller.statusText.contains("暂时无法访问"))
    }

    @Test("LC8 thumbnail URL for an item is the indexer's per-content thumbnail") func thumbnailURL() throws {
        let r = try Rig()
        let a = try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root); r.settle()
        let item = try #require(r.controller.items.first)
        #expect(r.controller.thumbnailURL(for: item) == LibraryIndexer.thumbnailURL(forKey: item.record.fileKey, in: r.thumbs))
        #expect(item.record.path == a)
    }
}

// Full-codebase audit 2026-10-20 (batch 02).
@Suite @MainActor struct LibraryControllerAuditTests {
    @Test("LC20 rescanning one folder keeps another folder's 'unavailable' warning")
    func unavailableKept() throws {
        let r = try Rig()
        let other = URL(fileURLWithPath: TestTemp.directory.appendingPathComponent("lc-other-\(UUID().uuidString)").path)
            .resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try r.file("a.mp4", seed: 1)
        r.controller.addRoot(r.root); r.controller.addRoot(other); r.settle()
        try FileManager.default.removeItem(atPath: other)              // the drive is unplugged
        r.controller.rescanAll(); r.settle()
        #expect(r.controller.unavailableRoots == [other])
        r.controller.rescan(r.root); r.settle()
        #expect(r.controller.unavailableRoots == [other], "still unplugged")
    }
}
