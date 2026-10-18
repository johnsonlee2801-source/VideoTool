import Foundation
import Testing
@testable import VideoTool

final class FakeThumbnailMaker: ThumbnailMaker {
    var requests: [(source: String, time: Double, url: URL)] = []
    /// When true, completions are held until `finishAll()`, like the real background maker.
    var deferred = false
    private var pending: [(URL, (Bool) -> Void)] = []
    func makeThumbnail(source: String, at time: Double, to url: URL, completion: @escaping (Bool) -> Void) {
        requests.append((source, time, url))
        if deferred { pending.append((url, completion)) } else { write(url); completion(true) }
    }
    func finishAll() {
        let jobs = pending; pending = []
        for (url, done) in jobs { write(url); done(true) }
    }
    private func write(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)
    }
}

/// Runs submitted blocks only when told to, to control async ordering in tests.
final class ManualQueue {
    private(set) var jobs: [() -> Void] = []
    func submit(_ job: @escaping () -> Void) { jobs.append(job) }
    func runAll() { while !jobs.isEmpty { jobs.removeFirst()() } }
    /// Newest first: models a slow fingerprint for an earlier file finishing last.
    func runAllNewestFirst() { while !jobs.isEmpty { jobs.removeLast()() } }
}

@MainActor
private final class Rig {
    let thumbs = FakeThumbnailMaker()
    let engine = FakeEngine()
    var now = Date(timeIntervalSince1970: 10_000)
    let store: BookmarkStore
    let thumbDir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
    let background = ManualQueue()
    let main = ManualQueue()
    var fingerprints: [String: String] = ["/m/film.mkv": "osh:abc"]
    lazy var controller = BookmarkController(store: store, engine: engine, now: { [unowned self] in self.now },
                                             thumbnailDirectory: thumbDir, thumbnails: thumbs,
                                             fingerprint: { [unowned self] in self.fingerprints[$0] },
                                             background: { [unowned self] in self.background.submit($0) },
                                             main: { [unowned self] in self.main.submit($0) })
    func settle() { background.runAll(); main.runAll() }
    init() throws {
        store = try BookmarkStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("bmc-\(UUID().uuidString).sqlite").path)
    }
    func open(_ key: String = "osh:abc", path: String = "/m/film.mkv", duration: Double = 600) {
        engine.state.duration = duration
        controller.fileOpened(key: key, path: path)
    }
}

@Suite @MainActor struct BookmarkControllerTests {
    @Test("C1 B adds a star at the current time without pausing, and stores it") func addsStar() throws {
        let r = try Rig(); r.open()
        r.engine.state.timePos = 123.4
        let feedback = r.controller.toggleAtCurrentTime()
        guard case .added(let b)? = feedback else { Issue.record("\(String(describing: feedback))"); return }
        #expect(b.time == 123.4)
        #expect(r.engine.togglePauseCount == 0 && r.engine.setPausedCalls.isEmpty)
        #expect(try r.store.bookmarks(for: "osh:abc").map(\.time) == [123.4])
        #expect(r.controller.bookmarks.map(\.time) == [123.4])
    }

    @Test("C2 adding a star requests a thumbnail of that file at that time, named after the star") func thumbnail() throws {
        let r = try Rig(); r.open(path: "/m/film.mkv")
        r.engine.state.timePos = 5
        guard case .added(let b)? = r.controller.toggleAtCurrentTime() else { Issue.record("not added"); return }
        #expect(r.thumbs.requests.count == 1)
        #expect(r.thumbs.requests.first?.source == "/m/film.mkv")
        #expect(r.thumbs.requests.first?.time == 5)
        #expect(r.thumbs.requests.first?.url == r.thumbDir.appendingPathComponent("\(b.id.uuidString).jpg"))
        #expect(r.controller.thumbnailURL(for: b) == r.thumbDir.appendingPathComponent("\(b.id.uuidString).jpg"))
    }

    @Test("C3 pressing B again right away at the same spot undoes the star") func undo() throws {
        let r = try Rig(); r.open()
        r.engine.state.timePos = 40
        _ = r.controller.toggleAtCurrentTime()
        r.now += 1; r.engine.state.timePos = 40.5
        #expect(r.controller.toggleAtCurrentTime() == .undone)
        #expect(try r.store.bookmarks(for: "osh:abc").isEmpty)
        #expect(r.controller.bookmarks.isEmpty)
    }

    @Test("C4 without an open file, B does nothing") func noFile() throws {
        let r = try Rig()
        #expect(r.controller.toggleAtCurrentTime() == nil)
    }

    @Test("C5 next / previous seek to 2 s before the star") func navigate() throws {
        let r = try Rig(); r.open()
        for t in [100.0, 300] { r.engine.state.timePos = t; _ = r.controller.toggleAtCurrentTime(); r.now += 10 }
        r.engine.state.timePos = 0
        #expect(r.controller.jumpToNext())
        #expect(r.engine.seeks.last == 98)
        r.engine.state.timePos = 98
        #expect(r.controller.jumpToNext())
        #expect(r.engine.seeks.last == 298)
        r.engine.state.timePos = 298.3
        #expect(r.controller.jumpToPrevious())
        #expect(r.engine.seeks.last == 98)
        r.now += 60; r.engine.state.timePos = 400      // played on to 400 s
        #expect(r.controller.jumpToNext() == false, "no star ahead: no seek")
    }

    @Test("C6 a click near a star snaps to 2 s before it; elsewhere it seeks where clicked") func clickSnap() throws {
        let r = try Rig(); r.open()
        r.engine.state.timePos = 200; _ = r.controller.toggleAtCurrentTime()
        #expect(r.controller.seekTarget(forClickAt: 201, tolerance: 2) == 198)
        #expect(r.controller.seekTarget(forClickAt: 250, tolerance: 2) == 250)
    }

    @Test("C7 stars belong to the file: reopening restores them, another file starts empty") func perFile() throws {
        let r = try Rig(); r.open("osh:A")
        r.engine.state.timePos = 12; _ = r.controller.toggleAtCurrentTime()
        r.open("osh:B", path: "/m/other.mp4")
        #expect(r.controller.bookmarks.isEmpty)
        r.open("osh:A", path: "/m/renamed.mkv")
        #expect(r.controller.bookmarks.map(\.time) == [12])
        #expect(try r.store.lastPath(for: "osh:A") == "/m/renamed.mkv")
    }

    @Test("C8 notes can be edited and stars deleted from the list; onChange fires each time") func editDelete() throws {
        let r = try Rig(); r.open()
        var changes = 0
        r.controller.onChange = { _ in changes += 1 }
        r.engine.state.timePos = 7
        guard case .added(let b)? = r.controller.toggleAtCurrentTime() else { Issue.record("not added"); return }
        r.controller.updateNote(b.id, "精彩")
        #expect(r.controller.bookmarks.first?.note == "精彩")
        r.controller.delete(b.id)
        #expect(r.controller.bookmarks.isEmpty)
        #expect(try r.store.bookmarks(for: "osh:abc").isEmpty)
        #expect(changes == 3, "add, note edit, delete (thumbnail readiness goes to onThumbnailReady)")
    }

    @Test("C9 jumping to a star from the list seeks 2 s before it") func jumpToStar() throws {
        let r = try Rig(); r.open()
        r.engine.state.timePos = 61; guard case .added(let b)? = r.controller.toggleAtCurrentTime() else { return }
        r.controller.jump(to: b)
        #expect(r.engine.seeks.last == 59)
    }

    @Test("C11 a finished thumbnail notifies the preview only; the list (and a note being typed) is not reloaded")
    func thumbnailReadyDoesNotReloadList() throws {
        let r = try Rig(); r.thumbs.deferred = true; r.open()
        r.engine.state.timePos = 9
        guard case .added(let b)? = r.controller.toggleAtCurrentTime() else { Issue.record("not added"); return }
        var listReloads = 0, ready: [UUID] = []
        r.controller.onChange = { _ in listReloads += 1 }
        r.controller.onThumbnailReady = { ready.append($0) }
        r.thumbs.finishAll()
        #expect(listReloads == 0)
        #expect(ready == [b.id])
        #expect(FileManager.default.fileExists(atPath: r.controller.thumbnailURL(for: b)!.path))
    }

    @Test("C12 undo before the thumbnail is written leaves no orphan image") func noOrphanThumbnail() throws {
        let r = try Rig(); r.thumbs.deferred = true; r.open()
        r.engine.state.timePos = 20
        guard case .added(let b)? = r.controller.toggleAtCurrentTime() else { Issue.record("not added"); return }
        r.now += 0.5
        #expect(r.controller.toggleAtCurrentTime() == .undone)
        r.thumbs.finishAll()
        #expect(!FileManager.default.fileExists(atPath: r.controller.thumbnailURL(for: b)!.path))
    }

    @Test("C13 review race: opening B before A's fingerprint returns never shows or writes stars under A")
    func fileSwitchRace() throws {
        let r = try Rig()
        r.fingerprints = ["/m/a.mkv": "osh:A", "/m/b.mkv": "osh:B"]
        try r.store.insert(Bookmark(id: UUID(), fileKey: "osh:A", time: 5, endTime: nil, note: "", createdAt: r.now))
        r.controller.open(path: "/m/a.mkv")
        r.controller.open(path: "/m/b.mkv")          // switch before A's fingerprint finished
        r.background.runAllNewestFirst()             // B is identified first, A's result arrives late
        r.main.runAll()
        #expect(r.controller.fileKey == "osh:B")
        #expect(r.controller.bookmarks.isEmpty, "A's stars must not appear for B")
        r.engine.state.timePos = 30
        _ = r.controller.toggleAtCurrentTime()
        #expect(try r.store.bookmarks(for: "osh:B").map(\.time) == [30])
        #expect(try r.store.bookmarks(for: "osh:A").map(\.time) == [5])
    }

    @Test("C14 B while the file is still being identified says so instead of silently doing nothing") func notReady() throws {
        let r = try Rig()
        r.controller.open(path: "/m/film.mkv")
        #expect(r.controller.toggleAtCurrentTime() == .notReady)
        r.settle()
        r.engine.state.timePos = 3
        guard case .added? = r.controller.toggleAtCurrentTime() else { Issue.record("should add once identified"); return }
    }

    @Test("C15 a file that cannot be identified reports .unavailable") func unavailable() throws {
        let r = try Rig()
        r.controller.open(path: "/m/unreadable.mkv")     // fingerprint returns nil
        r.settle()
        #expect(r.controller.toggleAtCurrentTime() == .unavailable)
        #expect(r.controller.fileKey == nil)
    }

    @Test("C16 rapid ⌥→ presses advance star by star even before mpv reports the new position") func rapidNext() throws {
        let r = try Rig(); r.open()
        for t in [100.0, 200, 300] { r.engine.state.timePos = t; _ = r.controller.toggleAtCurrentTime(); r.now += 10 }
        r.engine.state.timePos = 0                  // mpv still reports 0 after each seek
        r.controller.jumpToNext(); r.controller.jumpToNext(); r.controller.jumpToNext()
        #expect(r.engine.seeks == [98, 198, 298])
    }

    @Test("C17 two stars at the same moment are both kept; deleting one leaves the other") func duplicates() throws {
        let r = try Rig(); r.open()
        r.engine.state.timePos = 42; _ = r.controller.toggleAtCurrentTime()
        r.now += 5;                  _ = r.controller.toggleAtCurrentTime()
        #expect(r.controller.bookmarks.count == 2)
        r.controller.delete(r.controller.bookmarks[0].id)
        #expect(r.controller.bookmarks.map(\.time) == [42])
    }

    @Test("C18 B, B (undo), B again re-adds the star") func reAddAfterUndo() throws {
        let r = try Rig(); r.open()
        r.engine.state.timePos = 10
        _ = r.controller.toggleAtCurrentTime()
        r.now += 0.5; #expect(r.controller.toggleAtCurrentTime() == .undone)
        r.now += 0.5
        guard case .added? = r.controller.toggleAtCurrentTime() else { Issue.record("not re-added"); return }
        #expect(r.controller.bookmarks.count == 1)
    }

    @Test("C10 closing the file clears the list and makes B a no-op") func close() throws {
        let r = try Rig(); r.open()
        r.engine.state.timePos = 3; _ = r.controller.toggleAtCurrentTime()
        r.controller.fileClosed()
        #expect(r.controller.bookmarks.isEmpty)
        #expect(r.controller.toggleAtCurrentTime() == nil)
    }
}
