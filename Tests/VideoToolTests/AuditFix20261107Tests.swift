import AppKit
import Foundation
import Testing
@testable import VideoTool

/// Regressions for the 2026-11-07 audit of code added since 65d4a19.
/// Numbers refer to `.cc-suite/audits/audit-fix-20261107-findings.md`.
@Suite struct AuditFixStoreTests {
    @Test("A26 text with an embedded NUL round-trips through SQLite instead of being cut short")
    func embeddedNul() throws {
        let db = try SQLiteDatabase(path: TestTemp.directory.appendingPathComponent("nul-\(UUID().uuidString).sqlite").path)
        try db.exec("CREATE TABLE notes (body TEXT)")
        let note = "before\u{0000}after 日本語"
        try db.run("INSERT INTO notes VALUES (?)", [.text(note)])
        var read: [String] = []
        try db.query("SELECT body FROM notes", []) { read.append($0.text(0)) }
        #expect(read == [note])
    }

    @Test("A12 one child whose metadata cannot be read is skipped; its playable siblings remain")
    func childMetadataFailure() throws {
        let dir = TestTemp.directory.appendingPathComponent("partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Season"), withIntermediateDirectories: true)
        for name in ["1.mp4", "2.mp4", "3.mp4"] { try Data().write(to: dir.appendingPathComponent(name)) }
        let result = try FolderDirectory.read(dir.path) { url in
            if url.lastPathComponent == "2.mp4" { throw CocoaError(.fileNoSuchFile) }
            return try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        }
        #expect(result.videos.map { ($0 as NSString).lastPathComponent } == ["1.mp4", "3.mp4"])
        #expect(result.folders == [dir.appendingPathComponent("Season").path])
        #expect(throws: Error.self) { try FolderDirectory.read(dir.appendingPathComponent("missing").path) }
    }
}

@Suite(.serialized) @MainActor struct AuditFixPopupTests {
    @Test("A7 two subtitle sources with the same visible title both stay selectable")
    func duplicateSourceTitles() throws {
        let view = SubtitleTranscriptView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
        let video = URL(fileURLWithPath: "/tmp/v.mkv")
        view.setSources([SubtitleSourceOption(id: "website:en", title: "English", input: .file(video, bilingual: false)),
                         SubtitleSourceOption(id: "website:en-orig", title: "English", input: .file(video, bilingual: false))],
                        selected: "website:en-orig")
        #expect(view.sourcePopup.numberOfItems == 2)
        #expect(view.selectedSourceID == "website:en-orig")
        var chosen: [String] = []
        view.onSource = { chosen.append($0) }
        view.sourcePopup.selectItem(at: 0)
        NSApp.sendAction(try #require(view.sourcePopup.action), to: view.sourcePopup.target, from: view.sourcePopup)
        #expect(chosen == ["website:en"])
    }

    @Test("A11 a breadcrumb with repeated folder names keeps one entry per level and navigates to that level")
    func repeatedBreadcrumbNames() throws {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("crumb-\(UUID().uuidString).sqlite").path)
        let model = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() })
        let loader = FolderDirectoryLoader(read: { _ in FolderDirectory(folders: [], videos: []) }, background: { $0() }, main: { $0() })
        let folders = FolderBrowserViewController(controller: model, loader: loader, onOpen: { _ in })
        defer { folders.shutdown() }
        folders.enter("/Movies")
        folders.enter("/Movies/Movies")
        #expect(folders.pathPicker.numberOfItems == 3)
        #expect(folders.pathPicker.indexOfSelectedItem == 2)
        folders.pathPicker.selectItem(at: 1)
        NSApp.sendAction(try #require(folders.pathPicker.action), to: folders.pathPicker.target, from: folders.pathPicker)
        #expect(folders.directory == "/Movies")
    }
}

@Suite(.serialized) @MainActor struct AuditFixClipTests {
    private func markers() -> (BookmarkMarkersView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let markers = BookmarkMarkersView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        window.contentView?.addSubview(markers)
        markers.duration = 20; markers.clipRange = ClipRange(start: 2, end: 8)
        return (markers, window)
    }
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, in markers: BookmarkMarkersView, _ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: markers.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("A17 an off-centre click on a clip handle does not move it; a drag moves it by the pointer's travel")
    func offCentreHandle() throws {
        let (markers, window) = markers(); defer { window.orderOut(nil) }
        var selection = ClipSelection(); _ = selection.mark(2); _ = selection.mark(8)
        var adjustments: [Double] = []
        markers.onClipAdjust = { endpoint, time in adjustments.append(time); markers.clipRange = selection.adjust(endpoint, to: time, duration: 20) }
        // The start handle is at x = 40 (2 s of 20 s over 400 pt); grab it 6 pt to the right.
        markers.mouseDown(with: try event(.leftMouseDown, 46, 25, in: markers, window))
        markers.mouseUp(with: try event(.leftMouseUp, 46, 25, in: markers, window))
        #expect(adjustments.isEmpty && selection.range?.start == 2)
        markers.mouseDown(with: try event(.leftMouseDown, 46, 25, in: markers, window))
        markers.mouseDragged(with: try event(.leftMouseDragged, 106, 25, in: markers, window))
        markers.mouseUp(with: try event(.leftMouseUp, 106, 25, in: markers, window))
        #expect(abs((selection.range?.start ?? 0) - 5) < 0.000001)
    }

    @Test("A19 after a handle drag, hovering the star at the same place shows its preview again")
    func starPreviewAfterDrag() throws {
        let (markers, window) = markers(); defer { window.orderOut(nil) }
        let star = Bookmark(id: UUID(), fileKey: "test", time: 2, endTime: nil, note: "", createdAt: Date())
        markers.bookmarks = [star]
        markers.onClipAdjust = { _, _ in }
        var previews: [UUID?] = []
        markers.onHover = { bookmark, _ in previews.append(bookmark?.id) }
        markers.mouseMoved(with: try event(.mouseMoved, 40, markers.starCenterY, in: markers, window))
        markers.mouseDown(with: try event(.leftMouseDown, 40, 25, in: markers, window))
        markers.mouseUp(with: try event(.leftMouseUp, 40, 25, in: markers, window))
        markers.mouseMoved(with: try event(.mouseMoved, 40, markers.starCenterY, in: markers, window))
        #expect(previews == [star.id, nil, star.id])
    }

    @Test("A18 ending an unchanged time field keeps the endpoint's full precision")
    func unchangedFieldKeepsPrecision() throws {
        var selection = ClipSelection(); _ = selection.mark(2); _ = selection.mark(8)
        let view = ClipAdjustmentView(range: try #require(selection.range), duration: 30, fps: 24) { selection.adjust($0, to: $1, duration: 30) }
        view.endStepper.doubleValue += ClipAdjustment.step(fps: 24)
        NSApp.sendAction(try #require(view.endStepper.action), to: view.endStepper.target, from: view.endStepper)
        let stepped = 8 + 1.0 / 24
        view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: view.endField))
        view.commit(view.endField)
        #expect(abs((selection.range?.end ?? 0) - stepped) < 0.000001 && abs(view.range.end - stepped) < 0.000001)
        view.endField.stringValue = "0:09.000"; view.commit(view.endField)
        #expect(selection.range?.end == 9)
    }
}

@Suite(.serialized) @MainActor struct AuditFixNetworkHistoryTests {
    @Test("A5 a progress refresh keeps keyboard focus on the same record's same button")
    func focusSurvivesRefresh() throws {
        let name = "videotool-tests-history-focus-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NetworkWatchHistoryStore(defaults: defaults)
        let video = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        store.record(video, title: "Lecture", position: 10, duration: 100)
        let list = NetworkHistoryView(store: store) { _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        list.frame = window.contentView!.bounds; window.contentView?.addSubview(list)
        list.refresh(search: "")
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let restart = try #require(buttons(list).first { $0.title == L("从头播放") })
        #expect(window.makeFirstResponder(restart))
        store.record(video, title: "Lecture", position: 15, duration: 100)
        list.refresh(search: "")
        let focused = try #require(window.firstResponder as? NSButton, "focus fell back to \(String(describing: window.firstResponder))")
        #expect(focused !== restart && focused.title == L("从头播放") && focused.identifier?.rawValue == video.key)
    }
}

@Suite(.serialized) @MainActor struct AuditFixTranscriptTests {
    private let video = URL(fileURLWithPath: "/tmp/a.mkv")
    @Test("A9 the coordinator's own temporary display file never appears as a selectable source")
    func ownedFileIsNotASource() throws {
        let view = SubtitleTranscriptView(frame: .zero), loader = TranscriptLoaderStub()
        let coordinator = SubtitleTranscriptCoordinator(view: view, loader: loader, catalog: TranscriptCatalogStub())
        let owned = AppData.directory.appendingPathComponent("TranscriptCaptions/\(UUID().uuidString).srt")
        let external = SubtitleSourceOption(id: "file:/tmp/a.srt", title: "a.srt", input: .file(URL(fileURLWithPath: "/tmp/a.srt"), bilingual: false))
        let ownedOption = SubtitleSourceOption(id: "file:" + owned.path, title: owned.lastPathComponent, input: .file(owned, bilingual: false))
        coordinator.open(SubtitleTranscriptContext(target: "a", local: video, network: nil, external: [external, ownedOption], preferredSource: nil))
        loader.sourcesCompletion?(.success([SubtitleSourceOption(id: "embedded:2", title: "Track 2", input: .embedded(video, stream: 2))]))
        #expect(coordinator.sources.map(\.id) == ["file:/tmp/a.srt", "embedded:2"])
    }

    @Test("A10 a website caption file is written off the main thread; a superseded write never reaches the player")
    func displayWriteOffMain() throws {
        let view = SubtitleTranscriptView(frame: .zero), loader = TranscriptLoaderStub()
        let coordinator = SubtitleTranscriptCoordinator(view: view, loader: loader, catalog: TranscriptCatalogStub())
        var jobs: [() -> Void] = []
        coordinator.writeQueue = { jobs.append($0) }
        coordinator.mainQueue = { $0() }
        var shown: [URL] = []
        coordinator.onDisplayFile = { url, _ in shown.append(url) }
        let track = NetworkCaptionTrack(id: "en", title: "English", format: "json3", site: .youtube, url: URL(string: "https://www.youtube.com/api/timedtext"), inline: nil, headers: [:])
        let web = SubtitleSourceOption(id: "website:en", title: "English", input: .website(track))
        let document = SubtitleTranscript(cues: [SubtitleCue(start: 1, end: 2, text: "hello")])
        coordinator.open(SubtitleTranscriptContext(target: "a", local: video, network: nil, external: [web], preferredSource: nil))
        loader.sourcesCompletion?(.failure(.unavailable))
        loader.loadCompletion?(.success(document))
        #expect(shown.isEmpty && jobs.count == 1, "serialization and the disk write must not run on the main thread")
        func files() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: AppData.directory.appendingPathComponent("TranscriptCaptions").path)) ?? []).count }
        let before = files()
        coordinator.reset()
        jobs.removeFirst()()
        #expect(shown.isEmpty, "a write finished after reset must not be shown")
        #expect(files() == before, "the superseded file must be deleted, not left behind")
        coordinator.open(SubtitleTranscriptContext(target: "a", local: video, network: nil, external: [web], preferredSource: nil))
        loader.sourcesCompletion?(.failure(.unavailable))
        loader.loadCompletion?(.success(document))
        jobs.removeFirst()()
        #expect(shown.count == 1 && FileManager.default.fileExists(atPath: shown[0].path) && files() == before + 1)
        coordinator.reset()
    }
}

@Suite(.serialized) @MainActor struct AuditFixLibraryTests {
    private func library() throws -> (LibraryController, WatchHistoryStore, () -> Void) {
        let name = "videotool-tests-library-watch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("lw-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        for (i, n) in ["a.mp4", "b.mp4"].enumerated() {
            try store.upsert(MediaRecord(path: "/m/\(n)", fileKey: "k\(i)", size: 1, modified: Date(), duration: 600, width: 1280, height: 720, root: "/m"))
        }
        let history = WatchHistoryStore(defaults: defaults)
        let controller = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() }, history: history)
        return (controller, history, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("A15 watch progress moves videos into and out of the advanced view's Continue Watching section")
    func continueSectionFollowsProgress() throws {
        let (controller, history, cleanup) = try library(); defer { cleanup() }
        let browser = LibraryBrowserViewController(controller: controller, onOpen: { _ in })
        defer { browser.shutdown() }
        browser.showFolderBrowsing(false)
        controller.mode = .all
        let grid = NSCollectionView()
        #expect(browser.numberOfSections(in: grid) == 1)
        history.recordProgress(path: "/m/a.mp4", position: 120, duration: 600)
        browser.refreshWatchHistory()
        #expect(browser.numberOfSections(in: grid) == 2, "a newly resumable video must enter Continue Watching")
        #expect(browser.collectionView(grid, numberOfItemsInSection: 0) == 1)
        history.markFinished(path: "/m/a.mp4", duration: 600)
        browser.refreshWatchHistory()
        #expect(browser.numberOfSections(in: grid) == 1, "a finished video must leave Continue Watching")
    }

    @Test("A15b regrouping keeps the selected video selected, and a hidden grid reloads when shown")
    func regroupKeepsSelection() throws {
        let (controller, history, cleanup) = try library(); defer { cleanup() }
        let host = LibraryTestHost(controller: controller, onOpen: { _ in })
        defer { host.shutdown() }
        controller.mode = .all
        host.view.layoutSubtreeIfNeeded()
        let grid = host.gridForTesting
        grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]       // b.mp4
        history.recordProgress(path: "/m/a.mp4", position: 120, duration: 600)
        host.refreshWatchHistory()
        #expect(grid.selectionIndexPaths == [IndexPath(item: 1, section: 1)], "b.mp4 must stay selected under the new Continue section")
        host.showFolderBrowsing(true)
        history.markFinished(path: "/m/a.mp4", duration: 600)
        host.refreshWatchHistory()
        host.showFolderBrowsing(false)
        #expect(grid.numberOfSections == 1, "the hidden grid kept the old Continue section")
        #expect(grid.selectionIndexPaths == [IndexPath(item: 1, section: 0)], "b.mp4 must stay selected after a regroup while hidden")
    }

    @Test("A16 returning to folder browsing shows progress that changed while the advanced view was open")
    func hiddenFolderBrowserCatchesUp() throws {
        let (controller, history, cleanup) = try library(); defer { cleanup() }
        let browser = LibraryBrowserViewController(controller: controller, onOpen: { _ in })
        defer { browser.shutdown() }
        let folders = try #require(browser.folderBrowser)
        folders.enter("/m")
        history.recordProgress(path: "/m/a.mp4", position: 120, duration: 600)
        browser.refreshWatchHistory()
        let unfinished = try #require(folders.filterMenu().item(withTitle: L("继续观看")))
        #expect(NSApp.sendAction(try #require(unfinished.action), to: unfinished.target, from: unfinished))
        #expect(folders.visibleVideos.map(\.path) == ["/m/a.mp4"])
        browser.showFolderBrowsing(false)
        history.markFinished(path: "/m/a.mp4", duration: 600)
        browser.refreshWatchHistory()
        browser.showFolderBrowsing(true)
        #expect(folders.visibleVideos.isEmpty, "the finished video is still listed as unfinished")
    }

    @Test("A14 a hidden folder browser defers playback-driven refreshes until it is shown again")
    func hiddenBrowserDefersRefresh() throws {
        let (controller, _, cleanup) = try library(); defer { cleanup() }
        let folders = FolderBrowserViewController(controller: controller, onOpen: { _ in })
        defer { folders.shutdown() }
        folders.enter("/m")
        func status() -> [String] { folders.view.subviews.compactMap { ($0 as? NSTextField)?.stringValue } }
        let ended = L("本集已结束 · 下一集：%@", "b.mp4")
        folders.view.isHidden = true
        folders.currentPath = "/m/a.mp4"
        folders.setPlaybackNavigation(next: "/m/b.mp4", ended: true)
        #expect(!status().contains(ended), "a hidden browser rebuilt its snapshot on main")
        folders.view.isHidden = false
        folders.refreshIfNeeded()
        #expect(status().contains(ended))
    }

    @Test("A13 changing the selection restyles the visible rows without touching the rest")
    func selectionStylesVisibleRows() throws {
        let (controller, _, cleanup) = try library(); defer { cleanup() }
        let folders = FolderBrowserViewController(controller: controller, onOpen: { _ in })
        defer { folders.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = folders.view; folders.view.layoutSubtreeIfNeeded()
        folders.enter("/m")
        folders.view.layoutSubtreeIfNeeded()
        folders.table.selectRowIndexes([1], byExtendingSelection: false)
        let rows = (0..<folders.table.numberOfRows).map { folders.table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? SidebarMediaRow }
        #expect(rows.map { $0?.isSelected } == [false, true])
    }
}

@Suite(.serialized) struct AuditFixProcessTests {
    @Test("A1 cancelling a resolver also ends the helper processes it started (yt-dlp → Deno)")
    func cancelKillsDescendants() async throws {
        let pidFile = TestTemp.directory.appendingPathComponent("grandchild-\(UUID().uuidString).pid")
        let process = NetworkVideoProcess(timeout: 30)
        process.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 60 & echo $! > '\(pidFile.path)'; wait"]) { _ in }
        var grandchild: pid_t = 0
        let deadline = Date().addingTimeInterval(5)
        while grandchild == 0 && Date() < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { grandchild = pid }
            else { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(grandchild > 0)
        defer { kill(grandchild, SIGKILL) }
        process.cancel()
        let gone = Date().addingTimeInterval(3)
        while kill(grandchild, 0) == 0 && Date() < gone { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(grandchild, 0) != 0, "the grandchild outlived cancellation")
    }
}


@Suite @MainActor struct AuditFixBookmarkTests {
    @Test("A25 remembering a file's path on every load happens off the main thread")
    func rememberFileOffMain() throws {
        let store = try BookmarkStore(path: TestTemp.directory.appendingPathComponent("remember-\(UUID().uuidString).sqlite").path)
        var jobs: [() -> Void] = []
        let controller = BookmarkController(store: store, engine: FakeEngine(), thumbnails: FakeThumbnailMaker(),
            fingerprint: { _ in nil }, main: { $0() }, persist: { jobs.append($0) })
        let video = try NetworkVideo("https://youtu.be/BaW_jenozKc")
        controller.openNetwork(video)
        #expect(try store.lastPath(for: video.key) == nil, "the write ran on the main thread")
        #expect(controller.isReady)
        while !jobs.isEmpty { jobs.removeFirst()() }
        #expect(try store.lastPath(for: video.key) == video.url.absoluteString)
    }

    @Test("A25b path writes keep their order: the last opened path is what stays remembered")
    func rememberedPathOrder() async throws {
        let store = try BookmarkStore(path: TestTemp.directory.appendingPathComponent("order-\(UUID().uuidString).sqlite").path)
        let controller = BookmarkController(store: store, engine: FakeEngine(), thumbnails: FakeThumbnailMaker(), fingerprint: { _ in nil }, main: { $0() })
        for i in 0..<200 { controller.fileOpened(key: "osh:same", path: "/m/copy-\(i).mkv") }
        let deadline = Date().addingTimeInterval(5)
        while (try? store.lastPath(for: "osh:same")) != "/m/copy-199.mkv" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try store.lastPath(for: "osh:same") == "/m/copy-199.mkv")
    }
}
