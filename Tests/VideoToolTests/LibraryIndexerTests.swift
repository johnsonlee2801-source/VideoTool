import Foundation
import Testing
@testable import VideoTool

final class FakeProber: MediaProber {
    var calls: [String] = []
    var result = MediaProbe(duration: 90, width: 1920, height: 1080)
    var failing: Set<String> = []
    /// Probe succeeds but no frame can be rendered (audio-only, broken video track).
    var noFrame: Set<String> = []
    func probe(source: String, thumbnailTo url: URL?) -> MediaProbe? {
        calls.append((source as NSString).lastPathComponent)
        if failing.contains((source as NSString).lastPathComponent) { return nil }
        if noFrame.contains((source as NSString).lastPathComponent) { return result }
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data([0xFF, 0xD8, 0xFF]).write(to: url)
        }
        return result
    }
}

final class FakeTagger: ImageTagger {
    var calls = 0
    func tags(forImageAt url: URL) -> [(String, Double)] { calls += 1; return [("户外", 0.9)] }
}

private final class Rig {
    let root: String
    let store: LibraryStore
    let prober = FakeProber()
    let tagger = FakeTagger()
    let thumbs = FileManager.default.temporaryDirectory.appendingPathComponent("libthumbs-\(UUID().uuidString)")
    var failFingerprint: Set<String> = []
    var fingerprintCalls: [String] = []
    var cloudOnly: Set<String> = []
    lazy var indexer = LibraryIndexer(store: store, prober: prober, tagger: tagger,
                                      fingerprint: { [unowned self] p in
                                          self.fingerprintCalls.append((p as NSString).lastPathComponent)
                                          return self.failFingerprint.contains((p as NSString).lastPathComponent) ? nil : try? FileFingerprint.compute(path: p)
                                      },
                                      thumbnailDirectory: thumbs,
                                      scan: { [unowned self] root, cancelled in
                                          var r = LibraryScanner.scan(root: root, isCancelled: cancelled)
                                          for i in r.files.indices where self.cloudOnly.contains((r.files[i].path as NSString).lastPathComponent) {
                                              r.files[i].cloudOnly = true
                                          }
                                          return r
                                      })
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)").path)
            .resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        store = try LibraryStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot(root)
    }
    @discardableResult func file(_ rel: String, seed: UInt8, size: Int = 1000) throws -> String {
        let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8((Int($0) &+ Int(seed)) % 256) }).write(to: url)
        return url.path
    }
    func run(cancelAfter: Int? = nil) -> LibraryIndexer.Summary {
        var seen = 0
        return indexer.index(root: root, progress: { _ in seen += 1 }, isCancelled: { cancelAfter.map { seen >= $0 } ?? false })
    }
}

@Suite struct LibraryIndexerTests {
    @Test("X1 first pass adds every video with probe data, a thumbnail and tags") func firstPass() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1); try r.file("sub/b.mkv", seed: 2); try r.file("notes.txt", seed: 3)
        let s = r.run()
        #expect(s == .init(added: 2))
        let rows = try r.store.media(inRoot: r.root)
        #expect(rows.map { ($0.path as NSString).lastPathComponent } == ["a.mp4", "b.mkv"])
        #expect(rows.allSatisfy { $0.duration == 90 && $0.width == 1920 && $0.root == r.root })
        #expect(try r.store.roots() == [r.root])
        for row in rows {
            #expect(FileManager.default.fileExists(atPath: LibraryIndexer.thumbnailURL(forKey: row.fileKey, in: r.thumbs).path))
            #expect(try r.store.tags(for: row.fileKey) == ["户外"])
        }
    }

    @Test("X2 a second pass over unchanged files probes nothing") func incremental() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1); try r.file("b.mp4", seed: 2)
        _ = r.run()
        r.prober.calls.removeAll(); r.tagger.calls = 0
        #expect(r.run() == .init(unchanged: 2))
        #expect(r.prober.calls.isEmpty)
        #expect(r.tagger.calls == 0)
    }

    @Test("X3 a modified file is re-probed and its record updated") func modified() throws {
        let r = try Rig()
        let p = try r.file("a.mp4", seed: 1)
        _ = r.run()
        try Data((0..<2000).map { UInt8($0 % 7) }).write(to: URL(fileURLWithPath: p))
        r.prober.calls.removeAll(); r.prober.result.duration = 120
        #expect(r.run() == .init(updated: 1))
        #expect(r.prober.calls == ["a.mp4"])
        #expect(try r.store.record(at: p)?.duration == 120)
        #expect(try r.store.record(at: p)?.size == 2000)
    }

    @Test("X4 a file deleted from disk disappears from the library") func removed() throws {
        let r = try Rig()
        let a = try r.file("a.mp4", seed: 1); try r.file("b.mp4", seed: 2)
        _ = r.run()
        try FileManager.default.removeItem(atPath: a)
        #expect(r.run().removed == 1)
        #expect(try r.store.media(inRoot: r.root).map { ($0.path as NSString).lastPathComponent } == ["b.mp4"])
    }

    @Test("X5 cancelling stops early and never removes anything") func cancel() throws {
        let r = try Rig()
        for i in 0..<10 { try r.file("v\(i).mp4", seed: UInt8(i)) }
        _ = r.run()
        for i in 0..<10 { try FileManager.default.removeItem(atPath: r.root + "/v\(i).mp4") }
        for i in 10..<20 { try r.file("v\(i).mp4", seed: UInt8(i)) }
        let s = r.run(cancelAfter: 3)
        #expect(s.removed == 0, "an interrupted scan must not delete records")
        #expect(s.added < 10)
    }

    @Test("X6 one unreadable or unprobeable file does not stop the rest") func failures() throws {
        let r = try Rig()
        try r.file("bad.mp4", seed: 1); try r.file("broken.mp4", seed: 2); try r.file("good.mp4", seed: 3)
        r.failFingerprint = ["bad.mp4"]; r.prober.failing = ["broken.mp4"]
        let s = r.run()
        #expect(s.unreadable == 1, "bad.mp4: could not even be fingerprinted")
        #expect(s.probeFailed == 1, "broken.mp4: listed, but its details could not be read")
        #expect(s.added == 2, "a file that cannot be probed is still listed (duration unknown)")
        let names = try r.store.media(inRoot: r.root).map { ($0.path as NSString).lastPathComponent }
        #expect(names == ["broken.mp4", "good.mp4"])
        #expect(try r.store.record(at: r.root + "/broken.mp4")?.duration == 0)
    }

    @Test("X7 identical copies share one content key and are found as duplicates; tags computed once") func duplicates() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 9, size: 200_000); try r.file("copy/a.mp4", seed: 9, size: 200_000)
        try r.file("other.mp4", seed: 4, size: 200_000)
        _ = r.run()
        let items = try r.store.media(inRoot: r.root).map { LibraryItem(record: $0, tags: []) }
        let dups = LibraryGrouping.sections(items, mode: .duplicates)
        #expect(dups.count == 1 && dups[0].items.count == 2)
        #expect(r.tagger.calls == 2, "the copy reuses the original's tags")
    }

    @Test("X8 the library never changes the user's files") func readOnly() throws {
        let r = try Rig()
        let p = try r.file("a.mp4", seed: 5)
        let before = try FileManager.default.attributesOfItem(atPath: p)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: p))
        _ = r.run(); _ = r.run()
        let after = try FileManager.default.attributesOfItem(atPath: p)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        #expect(try Data(contentsOf: URL(fileURLWithPath: p)) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.root).sorted() == ["a.mp4"])
    }

    @Test("X9 progress reports every file with a running count and the total") func progress() throws {
        let r = try Rig()
        for i in 0..<4 { try r.file("v\(i).mp4", seed: UInt8(i)) }
        var reports: [LibraryIndexer.Progress] = []
        _ = r.indexer.index(root: r.root, progress: { reports.append($0) }, isCancelled: { false })
        #expect(reports.last?.done == 4 && reports.last?.total == 4)
        #expect(reports.map(\.done) == reports.map(\.done).sorted())
    }

    @Test("X10 thumbnail file names are safe for any content key") func thumbName() {
        let u = LibraryIndexer.thumbnailURL(forKey: "url:https://x.com/a b?c=1", in: URL(fileURLWithPath: "/t"))
        #expect(u.deletingLastPathComponent().path == "/t")
        #expect(!u.lastPathComponent.contains("/") && u.pathExtension == "jpg")
        #expect(LibraryIndexer.thumbnailURL(forKey: "osh:1", in: URL(fileURLWithPath: "/t")) !=
                LibraryIndexer.thumbnailURL(forKey: "osh:2", in: URL(fileURLWithPath: "/t")))
    }

    @Test("X11 review critical: a root that is gone (unplugged drive, renamed) keeps its index") func unavailableRoot() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1); try r.file("b.mp4", seed: 2)
        _ = r.run()
        let moved = r.root + "-unplugged"
        try FileManager.default.moveItem(atPath: r.root, toPath: moved)
        defer { try? FileManager.default.moveItem(atPath: moved, toPath: r.root) }
        let s = r.run()
        #expect(s.removed == 0)
        #expect(s.unavailable)
        #expect(try r.store.media(inRoot: r.root).count == 2)
    }

    @Test("X12 an unreadable sub-folder keeps its rows") func unreadableSubfolder() throws {
        let r = try Rig()
        try r.file("a.mp4", seed: 1); try r.file("locked/b.mp4", seed: 2)
        _ = r.run()
        let locked = r.root + "/locked"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        #expect(r.run().removed == 0)
        #expect(try r.store.media(inRoot: r.root).count == 2)
    }

    @Test("X13 a failed probe is retried on later scans (up to a limit), then left alone until the file changes")
    func probeRetry() throws {
        let r = try Rig()
        try r.file("flaky.mp4", seed: 1)
        r.prober.failing = ["flaky.mp4"]
        _ = r.run(); _ = r.run()
        #expect(r.prober.calls.filter { $0 == "flaky.mp4" }.count == 2, "retried on the second scan")
        r.prober.failing = []
        _ = r.run()
        #expect(try r.store.record(at: r.root + "/flaky.mp4")?.duration == 90)
        #expect(try r.store.record(at: r.root + "/flaky.mp4")?.status == .ok)

        try r.file("dead.mp4", seed: 2)
        r.prober.failing = ["dead.mp4"]; r.prober.calls.removeAll()
        for _ in 0..<(LibraryIndexer.maxProbeAttempts + 3) { _ = r.run() }
        #expect(r.prober.calls.filter { $0 == "dead.mp4" }.count == LibraryIndexer.maxProbeAttempts)
    }

    @Test("X14 a file with no picture (audio-only/broken video) is probed once, not on every scan") func noFrame() throws {
        let r = try Rig()
        try r.file("audio-only.mp4", seed: 1)
        r.prober.noFrame = ["audio-only.mp4"]
        _ = r.run(); _ = r.run(); _ = r.run()
        #expect(r.prober.calls == ["audio-only.mp4"])
        #expect(try r.store.record(at: r.root + "/audio-only.mp4")?.status == .noThumbnail)
    }

    @Test("X15 iCloud files that are not downloaded are listed but never read (no forced download)") func cloudOnly() throws {
        let r = try Rig()
        try r.file("cloud.mp4", seed: 1); try r.file("local.mp4", seed: 2)
        r.cloudOnly = ["cloud.mp4"]
        _ = r.run()
        #expect(r.fingerprintCalls == ["local.mp4"])
        #expect(!r.prober.calls.contains("cloud.mp4"))
        #expect(try r.store.record(at: r.root + "/cloud.mp4")?.status == .cloudOnly)
        r.cloudOnly = []
        _ = r.run()
        #expect(try r.store.record(at: r.root + "/cloud.mp4")?.status == .ok, "indexed once downloaded")
    }

    @Test("X16 OSHash collisions (same size, head and tail; different middle) are not marked as duplicates")
    func collisionNotDuplicate() throws {
        let r = try Rig()
        var bytes = (0..<400_000).map { UInt8($0 % 251) }
        try Data(bytes).write(to: URL(fileURLWithPath: r.root + "/x.mp4"))
        bytes[200_000] ^= 0xFF
        try Data(bytes).write(to: URL(fileURLWithPath: r.root + "/y.mp4"))
        _ = r.run()
        let rows = try r.store.media(inRoot: r.root)
        #expect(Set(rows.map(\.fileKey)).count == 1, "OSHash cannot tell them apart")
        let items = rows.map { LibraryItem(record: $0, tags: []) }
        #expect(LibraryGrouping.sections(items, mode: .duplicates).isEmpty)
    }

    @Test("X17 when a video's last copy disappears, its tags and thumbnail are cleaned up") func orphanCleanup() throws {
        let r = try Rig()
        let a = try r.file("a.mp4", seed: 1)
        _ = r.run()
        let key = try #require(try r.store.record(at: a)?.fileKey)
        try FileManager.default.removeItem(atPath: a)
        _ = r.run()
        #expect(try r.store.tags(for: key).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: LibraryIndexer.thumbnailURL(forKey: key, in: r.thumbs).path))
    }

    @Test("X18 if the folder is removed from the library mid-scan, the scan stops and writes nothing more")
    func rootRemovedMidScan() throws {
        let r = try Rig()
        for i in 0..<6 { try r.file("v\(i).mp4", seed: UInt8(i)) }
        var reports = 0
        _ = r.indexer.index(root: r.root, progress: { _ in
            reports += 1
            if reports == 3 { try? r.store.removeRoot(r.root) }
        }, isCancelled: { false })
        #expect(try r.store.media(inRoot: nil).isEmpty)
        #expect(try r.store.roots().isEmpty)
    }
}
