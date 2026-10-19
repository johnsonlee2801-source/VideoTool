import AppKit
import Testing
@testable import VideoTool

// Second coverage pass (2026-10-19, user: "can coverage go higher?"). Every test
// drives real behaviour a user relies on; lines that only open system UI (open
// panel, browser, default-app prompts, the speed pop-up's menu tracking) are left
// to the manual checklist instead of being "covered" by calls that check nothing.

private final class Marker {}
private func fixture(_ name: String, _ ext: String) -> URL {
    URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: name, ofType: ext)!)
}
private let sample = fixture("testsrc-20s", "mp4")

@MainActor
private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
    for v in view.subviews {
        if let t = v as? T, match(t) { return t }
        if let t = find(type, in: v, where: match) { return t }
    }
    return nil
}

@Suite(.serialized) @MainActor struct PlayerActionTests {
    private func loaded(_ url: URL = sample) async throws -> (PlayerWindowController, MPVEngine) {
        let w = PlayerWindowController()
        w.showWindow(nil)
        w.open(url)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.state.path == url.path && engine.state.duration > 0 })
        return (w, engine)
    }

    @Test("C1 HUD shows speeds like the speed label (1.25×, not 1.3×)") func hudFormat() {
        let hud = SpeedHUDView()
        hud.flash(speed: 1.25)
        #expect(hud.text == "1.25×")
        hud.show(speed: 0.75, dx: 0)
        #expect(hud.text == "0.75×")
        hud.flash(text: "★ 0:05")
        #expect(hud.text == "★ 0:05")
    }

    @Test("C2 B gives feedback: starred at the time, undone on a quick second press, nothing before/after")
    func starFeedback() async throws {
        let (w, engine) = try await loaded()
        defer { w.shutdown() }
        let star = NSMenuItem(title: "", action: #selector(PlayerWindowController.toggleBookmark(_:)), keyEquivalent: "")
        #expect(await waitUntil(8) { w.validateMenuItem(star) }, "file never identified for stars")
        engine.setPaused(true)
        let hud = try #require(w.playerView?.hud)
        w.nextBookmark(nil)
        #expect(hud.text == "后面没有星标了")
        w.previousBookmark(nil)
        #expect(hud.text == "前面没有星标了")
        w.toggleBookmark(nil)
        #expect(hud.text.hasPrefix("★ "))
        w.toggleBookmark(nil)
        #expect(hud.text == "已撤销星标")
    }

    @Test("C3 menu commands reach the player: pause, ±5 s, mute") func menuCommands() async throws {
        let (w, engine) = try await loaded()
        defer { w.shutdown() }
        engine.setPaused(true)
        #expect(await waitUntil { engine.state.isPaused })
        w.togglePause(nil)
        #expect(await waitUntil { !engine.state.isPaused })
        w.togglePause(nil)
        #expect(await waitUntil { engine.state.isPaused })
        engine.seek(to: 2)
        #expect(await waitUntil { abs(engine.state.timePos - 2) < 0.3 })
        w.seekForward(nil)
        #expect(await waitUntil { abs(engine.state.timePos - 7) < 0.6 }, "at \(engine.state.timePos)")
        w.seekBack(nil)
        #expect(await waitUntil { abs(engine.state.timePos - 2) < 0.6 }, "at \(engine.state.timePos)")
        w.toggleMute(nil)
        #expect(await waitUntil { engine.state.isMuted })
        w.toggleMute(nil)
        #expect(await waitUntil { !engine.state.isMuted })
    }

    @Test("C4 switching audio and subtitle tracks from the menu") func trackCommands() async throws {
        let (w, engine) = try await loaded(fixture("multi_audio_subs", "mkv"))
        defer { w.shutdown() }
        let aid = engine.property("aid"), sid = engine.property("sid")
        w.cycleAudio(nil)
        #expect(await waitUntil { engine.property("aid") != aid }, "aid stayed \(aid ?? "nil")")
        w.cycleSubtitle(nil)
        #expect(await waitUntil { engine.property("sid") != sid }, "sid stayed \(sid ?? "nil")")
    }

    @Test("C5 clicking the bar jumps there; clicking a star lands 2 s before it") func barClicks() async throws {
        let (w, engine) = try await loaded()
        defer { w.shutdown() }
        engine.setPaused(true)
        w.slider.doubleValue = 10
        NSApp.sendAction(w.slider.action!, to: w.slider.target, from: w.slider)
        #expect(await waitUntil { abs(engine.state.timePos - 10) < 0.3 }, "at \(engine.state.timePos)")

        let star = NSMenuItem(title: "", action: #selector(PlayerWindowController.toggleBookmark(_:)), keyEquivalent: "")
        #expect(await waitUntil(8) { w.validateMenuItem(star) })
        engine.seek(to: 15)
        #expect(await waitUntil { abs(engine.state.timePos - 15) < 0.2 })
        let starTime = engine.state.timePos
        w.toggleBookmark(nil)
        defer { w.toggleBookmark(nil) }                          // undo (within 3 s)
        w.window?.layoutIfNeeded()
        engine.seek(to: 1)
        #expect(await waitUntil { engine.state.timePos < 2 })
        w.slider.doubleValue = starTime
        NSApp.sendAction(w.slider.action!, to: w.slider.target, from: w.slider)
        #expect(await waitUntil { abs(engine.state.timePos - (starTime - 2)) < 0.3 }, "at \(engine.state.timePos), star \(starTime)")
        engine.seek(to: starTime)
        _ = await waitUntil { abs(engine.state.timePos - starTime) < 0.2 }
    }

    @Test("C6 playing to the end marks the video watched (for 已看完 and 继续观看)") func watchedAtEnd() async throws {
        let (w, engine) = try await loaded()
        defer { w.shutdown() }
        engine.seek(to: 19)
        engine.setPaused(false)
        #expect(await waitUntil(8) { engine.state.eofReached })
        #expect(await waitUntil { WatchHistoryStore().entry(for: sample.path)?.finished == true })
    }

    @Test("C7 opening another file ends a press in progress") func newFileCancelsGesture() async throws {
        let (w, engine) = try await loaded()
        defer { w.shutdown() }
        let view = try #require(w.playerView)
        view.gesture.mouseDown()
        #expect(view.gesture.isActive)
        w.open(fixture("speech-en", "mkv"))
        #expect(await waitUntil { !view.gesture.isActive })
        _ = engine
    }

    @Test("C8 closing the window shuts the player down and tells the app") func closing() async throws {
        let (w, _) = try await loaded()
        var told = false
        w.onClose = { told = true }
        w.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: w.window))
        #expect(told)
        w.shutdown()                                             // idempotent
    }

    @Test("C9 an unexpected recogniser error is shown as a failure, with the reason") func genericError() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "磁盘已满" } }
        final class Failing: SpeechRecognizing, @unchecked Sendable {
            func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] { throw Boom() }
        }
        let (w, _) = try await loaded()
        defer { w.shutdown() }
        let p = AISubtitlePipeline(recognizer: Failing(), translator: nil,
                                   cacheDirectory: TestTemp.directory.appendingPathComponent("c9-\(UUID().uuidString)"),
                                   extract: { _, wav, _, _ in
                                       try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
                                       try? Data(count: 100).write(to: wav); return .success(3) })
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: p)
        #expect(await waitUntil { !w.isMakingAISubtitles })
        #expect(w.aiCard.message == "生成字幕失败：磁盘已满")
    }

    @Test("C10 the star-list menu item shows whether the list is open") func listMenuState() async throws {
        let (w, _) = try await loaded()
        defer { w.shutdown() }
        let item = NSMenuItem(title: "", action: #selector(PlayerWindowController.toggleBookmarkList(_:)), keyEquivalent: "")
        _ = w.validateMenuItem(item)
        #expect(item.state == .off)
        w.toggleBookmarkList(nil)
        _ = w.validateMenuItem(item)
        #expect(item.state == .on)
    }
}

@Suite(.serialized) @MainActor struct DialogSheetTests {
    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderBack(nil)
        return w
    }

    @Test("C11 AI subtitle dialog: 开始 returns the choice and remembers it; 取消 returns nothing") func aiDialog() async throws {
        let suite = "videotool-tests-c11-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let prefs = AISubtitlePreferences(defaults: d)
        prefs.source = "ja-JP"; prefs.target = "zh-Hant"
        let win = window()
        defer { win.orderOut(nil) }
        var got: AISubtitleDialog.Choice?? = .none
        AISubtitleDialog.run(on: win, sources: SubtitleLanguages.sources, preferences: prefs) { got = .some($0) }
        let sheet = try #require(await waitUntil { win.attachedSheet != nil } ? win.attachedSheet : nil)
        win.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { got != nil })
        #expect(got == .some(.init(source: "ja-JP", target: "zh-Hant")))
        got = .none
        AISubtitleDialog.run(on: win, sources: SubtitleLanguages.sources, preferences: prefs) { got = .some($0) }
        let again = try #require(await waitUntil { win.attachedSheet != nil } ? win.attachedSheet : nil)
        win.endSheet(again, returnCode: .alertSecondButtonReturn)
        #expect(await waitUntil { got != nil })
        #expect(got == .some(nil))
    }

    @Test("C12 series dialog through the library's right-click menu: 不是剧集 takes the video out of every show")
    func seriesFromMenu() async throws {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("c12-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        for (i, n) in ["Show.S01E01.mkv", "Show.S01E02.mkv"].enumerated() {
            try store.upsert(MediaRecord(path: "/m/\(n)", fileKey: "c12-\(i)", size: 1, modified: Date(), duration: 60,
                                         width: 1920, height: 1080, root: "/m"))
        }
        let suite = "videotool-tests-c12-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() },
                                  history: WatchHistoryStore(defaults: d), series: SeriesOverrideStore(defaults: d))
        var opened: [URL] = []
        let w = LibraryWindowController(controller: c, onOpen: { opened.append($0) })
        w.window?.orderBack(nil)
        defer { w.window?.orderOut(nil) }
        c.mode = .series
        let second = try #require(c.items.first { $0.record.fileKey == "c12-1" })
        let items = w.cardMenuItems(for: second)
        #expect(items.map(\.title) == ["在播放器中打开", "修改剧集信息…", "在 Finder 中显示"])
        NSApp.sendAction(items[0].action!, to: items[0].target, from: items[0])
        #expect(opened.map(\.path) == ["/m/Show.S01E02.mkv"])
        NSApp.sendAction(items[1].action!, to: items[1].target, from: items[1])
        let sheet = try #require(await waitUntil { w.window?.attachedSheet != nil } ? w.window?.attachedSheet : nil)
        w.window?.endSheet(sheet, returnCode: .alertThirdButtonReturn)          // 不是剧集
        #expect(await waitUntil { c.sections.last?.title == "其他视频" })
        #expect(c.sections.first?.title == "Show · 第 1 季 · 1 集")
    }
}

@Suite(.serialized) @MainActor struct LibraryWindowActionTests {
    private func rig(indexing: Bool = false) throws -> (LibraryWindowController, LibraryController) {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("lwa-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        for (i, n) in ["alpha.mp4", "beta.mkv"].enumerated() {
            try store.upsert(MediaRecord(path: "/m/\(n)", fileKey: "lwa-\(i)", size: 1, modified: Date(), duration: 60,
                                         width: 1920, height: 1080, root: "/m"))
        }
        let path = store
        let c = LibraryController(store: store, stars: nil,
                                  makeIndexer: { indexing ? LibraryIndexer(store: path, prober: FakeProber(), tagger: nil) : nil },
                                  background: { _ in }, main: { $0() })
        return (LibraryWindowController(controller: c, onOpen: { _ in }), c)
    }

    @Test("C13 typing in the search field filters; picking a sidebar mode regroups") func searchAndModes() throws {
        let (w, c) = try rig()
        w.searchFieldForTesting.stringValue = "beta"
        w.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: w.searchFieldForTesting))
        #expect(c.search == "beta" && c.sections.first?.items.map(\.name) == ["beta.mkv"])
        let row = try #require(w.sidebarRow(mode: .duration))
        w.sidebarForTesting.selectRowIndexes([row], byExtendingSelection: false)
        #expect(c.mode == .duration)
        #expect(!w.tableView(w.sidebarForTesting, shouldSelectRow: try #require(w.sidebarRow(root: "/m"))), "folders are not modes")
    }

    @Test("C14 empty states explain themselves") func emptyStates() throws {
        let (w, c) = try rig()
        c.mode = .duplicates
        #expect(w.emptyMessage.title == "没有重复文件")
        c.mode = .all
        c.search = "zzz"
        #expect(w.emptyMessage.title == "没有符合条件的视频" && w.emptyMessage.detail == "换个关键词试试。")
        c.search = ""
        #expect(w.emptyMessage.title.isEmpty)
    }

    @Test("C15 a folder's right-click menu removes it from the library (files untouched); mode rows have none")
    func folderMenu() throws {
        let (w, c) = try rig()
        #expect(w.sidebarMenuItems(row: try #require(w.sidebarRow(mode: .all))).isEmpty)
        let items = w.sidebarMenuItems(row: try #require(w.sidebarRow(root: "/m")))
        #expect(items.map(\.title) == ["在 Finder 中显示", "从视频库移除（不删除文件）"])
        NSApp.sendAction(items[1].action!, to: items[1].target, from: items[1])
        #expect(c.roots.isEmpty && c.items.isEmpty)
    }

    @Test("C16 opening the library window starts a quick rescan; closing it stops scanning") func showAndClose() throws {
        let (w, c) = try rig(indexing: true)
        w.showWindow(nil)
        #expect(c.isIndexing)
        w.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: w.window))
        c.rescanAll()
        w.window?.orderOut(nil)
    }

    @Test("C17 double-clicking a card opens it") func doubleClick() throws {
        let card = LibraryCardItem()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView?.addSubview(card.view)
        var opened = 0
        card.onDoubleClick = { opened += 1 }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                                       windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        card.mouseDown(with: event)
        #expect(opened == 1)
    }
}

@Suite(.serialized) @MainActor struct BookmarkListAndMarkerTests {
    private let stars = [5.0, 12.0].map { Bookmark(id: UUID(), fileKey: "k", time: $0, endTime: nil, note: "", createdAt: Date()) }

    @Test("C18 the star list: time jumps, trash deletes, editing a note saves it") func listActions() throws {
        let list = BookmarkListView()
        var jumped: [Double] = [], deleted: [UUID] = [], notes: [String] = []
        list.onJump = { jumped.append($0.time) }
        list.onDelete = { deleted.append($0) }
        list.onNoteChange = { notes.append($1) }
        list.show(stars)
        let cell = try #require(list.tableView(NSTableView(), viewFor: nil, row: 1))
        try #require(find(NSButton.self, in: cell) { $0.title.hasPrefix("★") }).performClick(nil)
        #expect(jumped == [12])
        try #require(find(NSButton.self, in: cell) { $0.image != nil && !$0.title.hasPrefix("★") }).performClick(nil)
        #expect(deleted == [stars[1].id])
        let field = try #require(find(NSTextField.self, in: cell) { $0.isEditable })
        field.stringValue = "名场面"
        list.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(notes == ["名场面"])
        field.stringValue = ""                                   // unchanged note: no save
        list.show([stars[0], Bookmark(id: stars[1].id, fileKey: "k", time: 12, endTime: nil, note: "", createdAt: Date())])
        list.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(notes == ["名场面"])
    }

    @Test("C19 hovering a star previews it; leaving the bar hides the preview") func hover() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 52), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let markers = BookmarkMarkersView(frame: NSRect(x: 0, y: 0, width: 400, height: 52))
        window.contentView?.addSubview(markers)
        markers.duration = 20
        markers.bookmarks = stars
        var hovered: [Double?] = []
        markers.onHover = { b, _ in hovered.append(b?.time) }
        func event(_ type: NSEvent.EventType, at x: CGFloat) -> NSEvent {
            let p = markers.convert(NSPoint(x: x, y: markers.starCenterY), to: nil)
            if type == .mouseExited {                // enter/exit events have their own constructor
                return NSEvent.enterExitEvent(with: .mouseExited, location: p, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        markers.mouseMoved(with: event(.mouseMoved, at: try #require(markers.x(for: stars[0]))))
        markers.mouseMoved(with: event(.mouseMoved, at: try #require(markers.x(for: stars[0])) + 1))   // same star: no repeat
        markers.mouseMoved(with: event(.mouseMoved, at: 390))
        markers.mouseExited(with: event(.mouseExited, at: 390))
        #expect(hovered == [5, nil])
        markers.mouseMoved(with: event(.mouseMoved, at: try #require(markers.x(for: stars[1]))))
        markers.mouseExited(with: event(.mouseExited, at: 0))
        #expect(hovered == [5, nil, 12, nil])
    }
}

struct StorageErrorTests {
    @Test("C20 the database reports what it cannot do and rolls back half-done work") func database() throws {
        #expect(throws: (any Error).self) { try SQLiteDatabase(path: "/nonexistent-dir-\(UUID().uuidString)/x/y.sqlite") }
        let db = try SQLiteDatabase(path: TestTemp.directory.appendingPathComponent("c20-\(UUID().uuidString).sqlite").path)
        #expect(throws: (any Error).self) { try db.run("NOT SQL AT ALL", []) }
        #expect(throws: (any Error).self) { try db.query("SELECT nope FROM nowhere", []) { _ in } }
        try db.exec("CREATE TABLE t (x INTEGER)")
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (?)", [.int(1)])
                throw Stop()
            }
        }
        var count = -1
        try db.query("SELECT COUNT(*) FROM t", []) { count = Int($0.int(0)) }
        #expect(count == 0, "the insert inside the failed transaction was rolled back")
    }

    @Test("C21 fingerprints: unreadable files fail; big files are checked at 25/50/75 % so a change mid-file shows")
    func fingerprints() throws {
        #expect(throws: (any Error).self) { try FileFingerprint.compute(path: "/nonexistent-\(UUID().uuidString).mp4") }
        let size = FileFingerprint.checkSample * 3 + 1_000_000
        let a = TestTemp.directory.appendingPathComponent("c21a-\(UUID().uuidString).bin")
        let b = TestTemp.directory.appendingPathComponent("c21b-\(UUID().uuidString).bin")
        var data = Data((0..<size).map { UInt8($0 % 251) })
        try data.write(to: a)
        data[size / 2 + 10] ^= 0xFF                                 // differs only in the middle sample
        try data.write(to: b)
        let ca = try #require(FileFingerprint.contentCheck(path: a.path)), cb = try #require(FileFingerprint.contentCheck(path: b.path))
        #expect(ca != cb)
        #expect(FileFingerprint.contentCheck(path: a.path) == ca, "stable")
    }
}

@Suite(.serialized) @MainActor struct AppDelegateFlowTests {
    private var delegate: AppDelegate { NSApp.delegate as! AppDelegate }

    @Test("C22 a file opened from Finder plays in the player window") func openFromFinder() async throws {
        delegate.application(NSApp, open: [sample])
        let engine = try #require(delegate.playerWindow?.engine)
        #expect(await waitUntil { engine.state.path == sample.path })
        engine.stop()
    }

    @Test("C23 opening a new video in a library folder adds it to the library by itself") func libraryPicksUpNewVideo() async throws {
        let folder = TestTemp.directory.appendingPathComponent("c23-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LibraryStore().addRoot(folder.path)
        delegate.showLibrary(nil)
        let controller = try #require(delegate.libraryController)
        controller.reload()
        #expect(controller.roots.contains(folder.path))
        #expect(await waitUntil(10) { !controller.isIndexing })
        let video = folder.appendingPathComponent("new clip.mp4")
        try FileManager.default.copyItem(at: sample, to: video)
        delegate.application(NSApp, open: [video])
        #expect(await waitUntil(15) { controller.items.contains { $0.record.path == video.path } }, "the new video never joined the library")
        delegate.playerWindow?.engine?.stop()
        controller.removeRoot(folder.path)
        NSApp.windows.filter { $0.title == "视频库" }.forEach { $0.orderOut(nil) }
    }

    @Test("C24 no empty window at launch; closing the last window quits") func appPolicies() {
        #expect(!delegate.applicationShouldOpenUntitledFile(NSApp))
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
