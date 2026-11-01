import Foundation
import AppKit
import Testing
@testable import VideoTool

private func folderItem(_ path: String, root: String = "/a", tags: [String] = []) -> VideoTool.LibraryItem {
    VideoTool.LibraryItem(record: MediaRecord(path: path, fileKey: path, size: 1, modified: Date(), duration: 60, width: 1280, height: 720, root: root), tags: tags)
}

@Suite(.serialized) @MainActor struct FolderBrowserUITests {
    private func browser() throws -> (LibraryBrowserViewController, URL, LibraryController, () -> [URL]) {
        let root = TestTemp.directory.appendingPathComponent("folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Season 1"), withIntermediateDirectories: true)
        let store = try LibraryStore(path: root.appendingPathComponent("index.sqlite").path)
        _ = try store.addRoot(root.path)
        for name in ["1.mp4", "2.mp4", "10.mp4", "Season 1/1.mp4"] {
            let url = root.appendingPathComponent(name)
            try Data().write(to: url)
            try store.upsert(folderItem(url.path, root: root.path, tags: name == "2.mp4" ? ["旅行"] : ["学习"]).record)
            try store.setTags((name == "2.mp4" ? ["旅行"] : ["学习"]).map { ($0, 1.0) }, for: url.path, source: "test")
        }
        let model = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() })
        var opened: [URL] = []
        return (LibraryBrowserViewController(controller: model, onOpen: { opened.append($0) }), root, model, { opened })
    }

    @Test("FU1 the main library opens in folder mode; entering and returning preserve natural order")
    func navigation() throws {
        let (browser, root, _, _) = try browser()
        defer { browser.shutdown() }
        let folders = try #require(browser.folderBrowser)
        #expect(!folders.view.isHidden)
        folders.enter(root.path)
        #expect(folders.visibleFolders.map(\.path) == [root.appendingPathComponent("Season 1").path])
        #expect(folders.visibleVideos.map { ($0.path as NSString).lastPathComponent } == ["1.mp4", "2.mp4", "10.mp4"])
        folders.enter(root.appendingPathComponent("Season 1").path)
        folders.goUp(nil)
        #expect(folders.directory == root.path && folders.visibleVideos.count == 3)
        #expect(folders.tableView(folders.table, heightOfRow: 0) == 32)
        #expect(folders.tableView(folders.table, heightOfRow: 1) == 62)
    }

    @Test("FU2 real table action opens one file; current-folder search survives refresh and advanced-view roundtrip")
    func openAndSearch() throws {
        let (browser, root, model, opened) = try browser()
        defer { browser.shutdown() }
        let folders = try #require(browser.folderBrowser)
        folders.enter(root.path)
        folders.table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(NSApp.sendAction(try #require(folders.table.doubleAction), to: folders.table.target, from: folders.table))
        #expect(opened().map(\.lastPathComponent) == ["2.mp4"])
        folders.searchField.stringValue = "10"
        folders.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(folders.visibleVideos.map { ($0.path as NSString).lastPathComponent } == ["10.mp4"])
        model.reload(); browser.showFolderBrowsing(false); browser.showFolderBrowsing(true)
        #expect(folders.directory == root.path && folders.searchField.stringValue == "10")
        #expect(folders.visibleVideos.count == 1)
    }

    @Test("FU3 returning to a temporary folder restores search and selection after the asynchronous read")
    func temporarySelection() throws {
        let (host, root, model, _) = try browser()
        defer { host.shutdown() }
        var jobs: [() -> Void] = []
        let loader = FolderDirectoryLoader(read: { path in FolderDirectory(folders: [], videos: [path + "/1.mp4", path + "/2.mp4"]) },
            background: { jobs.append($0) }, main: { $0() })
        let folders = FolderBrowserViewController(controller: model, loader: loader, onOpen: { _ in })
        defer { folders.shutdown() }
        folders.enter("/temporary-videos"); jobs[0]()
        folders.table.selectRowIndexes([1], byExtendingSelection: false)
        folders.searchField.stringValue = "2"
        folders.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        folders.enter(root.path)
        folders.enter("/temporary-videos"); jobs[1]()
        #expect(folders.searchField.stringValue == "2" && folders.visibleVideos.map(\.path) == ["/temporary-videos/2.mp4"])
        #expect(folders.table.selectedRow == 0, "selection must restore after rows arrive, not before")
        folders.enter("/older-request")
        folders.enter(root.path); jobs[2]()
        #expect(folders.directory == root.path && folders.visibleVideos.count == 3)
    }

    @Test("FU4 small previews retain the iCloud-download warning instead of implying the file is ready")
    func cloudWarning() {
        var item = folderItem("/a/cloud.mp4")
        item.record.status = .cloudOnly
        let row = SidebarMediaRow(frame: NSRect(x: 0, y: 0, width: 250, height: 62), compact: true)
        row.configure(path: item.record.path, item: item, watch: nil, thumbnail: nil, recent: false, current: false)
        #expect(row.accessibilityLabel()?.contains(L("iCloud 未下载")) == true)
    }

    @Test("FU5 content-tag menu filters current-layer videos, and removing a file never opens another one")
    func filtersAndMissingFile() throws {
        let (host, root, _, opened) = try browser()
        defer { host.shutdown() }
        let folders = try #require(host.folderBrowser)
        folders.enter(root.path)
        let tag = try #require(folders.filterMenu().item(withTitle: L("旅行")))
        #expect(NSApp.sendAction(try #require(tag.action), to: tag.target, from: tag))
        #expect(folders.visibleVideos.map { ($0.path as NSString).lastPathComponent } == ["2.mp4"])
        #expect(folders.visibleFolders.count == 1, "filtering videos does not hide navigation")
        try FileManager.default.removeItem(at: root.appendingPathComponent("2.mp4"))
        folders.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(NSApp.sendAction(try #require(folders.table.doubleAction), to: folders.table.target, from: folders.table))
        #expect(opened().isEmpty)
        let labels = folders.view.subviews.compactMap { $0 as? NSTextField }
        #expect(labels.contains { $0.stringValue == L("文件已不可用：%@", root.appendingPathComponent("2.mp4").path) })
    }

    @Test("FU6 an indexed directory preference restores between browser instances without changing the index")
    func preferences() throws {
        let (host, root, model, _) = try browser()
        defer { host.shutdown() }
        let suite = "videotool-tests-folders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FolderBrowserViewController(controller: model, defaults: defaults, onOpen: { _ in })
        first.enter(root.appendingPathComponent("Season 1").path); first.shutdown()
        let second = FolderBrowserViewController(controller: model, defaults: defaults, onOpen: { _ in })
        defer { second.shutdown() }
        #expect(second.directory == root.appendingPathComponent("Season 1").path && second.visibleVideos.count == 1)
        #expect(model.items.count == 4 && FileManager.default.fileExists(atPath: root.appendingPathComponent("1.mp4").path))
    }

    @Test("FU7 unreadable temporary folders explain the error even when the current video has finished")
    func unavailableFolder() throws {
        let (host, _, model, opened) = try browser()
        defer { host.shutdown() }
        var jobs: [() -> Void] = []
        let loader = FolderDirectoryLoader(read: { _ in throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline-fixture"]) },
            background: { jobs.append($0) }, main: { $0() })
        let folders = FolderBrowserViewController(controller: model, loader: loader, onOpen: { _ in })
        defer { folders.shutdown() }
        folders.currentPath = "/offline-folder/current.mp4"
        folders.setPlaybackNavigation(next: "/next.mp4", ended: true)
        folders.enter("/offline-folder"); jobs[0]()
        #expect(folders.visibleVideos.isEmpty && opened().isEmpty)
        #expect(folders.view.subviews.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == L("无法读取文件夹：%@", "offline-fixture")
        })
        #expect(model.roots.count == 1, "a temporary browse never adds a library root")
    }

    @Test("FU8 library notices remain visible in folder mode when adding an already-covered directory")
    func libraryNotice() throws {
        let (host, root, model, _) = try browser()
        defer { host.shutdown() }
        let folders = try #require(host.folderBrowser)
        model.addRoot(root.appendingPathComponent("Season 1").path)
        let notice = try #require(model.notice)
        #expect(folders.view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == notice })
    }

    @Test("FU9 end-of-video hints describe only the playing folder, not another folder being browsed")
    func endMessageScope() throws {
        let (host, root, _, _) = try browser()
        defer { host.shutdown() }
        let folders = try #require(host.folderBrowser)
        folders.currentPath = root.appendingPathComponent("1.mp4").path
        folders.enter(root.path)
        folders.setPlaybackNavigation(next: root.appendingPathComponent("2.mp4").path, ended: true)
        #expect(folders.view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L("本集已结束 · 下一集：%@", "2.mp4") })
        folders.enter(root.appendingPathComponent("Season 1").path)
        #expect(folders.view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L("本层 %@ 个视频 · %@ 个子文件夹", "1", "0") })
    }

    @Test("FU10 successfully opening another video clears an earlier unavailable-file message")
    func successfulOpenClearsError() throws {
        let (host, root, _, opened) = try browser()
        defer { host.shutdown() }
        let folders = try #require(host.folderBrowser)
        folders.enter(root.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("2.mp4"))
        folders.table.selectRowIndexes([2], byExtendingSelection: false)
        let action = try #require(folders.table.doubleAction)
        #expect(NSApp.sendAction(action, to: folders.table.target, from: folders.table))
        folders.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(NSApp.sendAction(action, to: folders.table.target, from: folders.table))
        #expect(opened().map(\.lastPathComponent) == ["1.mp4"])
        #expect(!folders.view.subviews.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == L("文件已不可用：%@", root.appendingPathComponent("2.mp4").path)
        })
    }
}

@Suite struct FolderBrowserTests {
    @Test("FB1 show direct child folders, direct videos and accurate subtree counts, never sibling prefixes")
    func hierarchy() {
        let items = [folderItem("/a/2.mp4"), folderItem("/a/1.mp4"), folderItem("/a/sub/deep/3.mp4"), folderItem("/ab/4.mp4", root: "/ab")]
        let s = FolderBrowserModel.snapshot(path: "/a", roots: ["/a", "/ab"], items: items)
        #expect(s.folders.map(\.path) == ["/a/sub"])
        #expect(s.folders.first?.videoCount == 1)
        #expect(s.videos.map(\.path) == ["/a/1.mp4", "/a/2.mp4"])
        #expect(FolderBrowserModel.snapshot(path: "/a/sub", roots: ["/a"], items: items).folders.map(\.path) == ["/a/sub/deep"])
    }

    @Test("FB2 roots with identical names stay distinct; empty roots remain navigable")
    func roots() {
        let s = FolderBrowserModel.snapshot(path: nil, roots: ["/b/videos", "/a/videos"], items: [folderItem("/a/videos/1.mp4", root: "/a/videos")])
        #expect(Set(s.folders.map(\.path)) == ["/a/videos", "/b/videos"])
        #expect(s.folders.first { $0.path == "/b/videos" }?.videoCount == 0)
        #expect(s.videos.isEmpty)
    }

    @Test("FB3 search and tag filters apply only to current-layer videos; natural sequence is stable")
    func filtering() {
        let items = [folderItem("/a/10.mp4", tags: ["学习"]), folderItem("/a/2.mp4", tags: ["旅行"]), folderItem("/a/1.mp4", tags: ["学习"]), folderItem("/a/sub/1.mp4")]
        let all = FolderBrowserModel.snapshot(path: "/a", roots: ["/a"], items: items)
        #expect(all.videos.map(\.path) == ["/a/1.mp4", "/a/2.mp4", "/a/10.mp4"])
        let filtered = FolderBrowserModel.snapshot(path: "/a", roots: ["/a"], items: items, search: "1", tag: "学习")
        #expect(filtered.videos.map(\.path) == ["/a/1.mp4", "/a/10.mp4"])
        #expect(filtered.folders == all.folders)
    }

    @Test("FB4 watch filters distinguish never-opened, unfinished and completed videos")
    func watchFilters() {
        let now = Date()
        let rows = [FolderBrowserVideo(path: "/a/1.mp4", item: nil), FolderBrowserVideo(path: "/a/2.mp4", item: nil), FolderBrowserVideo(path: "/a/3.mp4", item: nil)]
        let history = ["/a/2.mp4": WatchEntry(position: 20, duration: 100, watchedAt: now, finished: false),
                       "/a/3.mp4": WatchEntry(position: 10, duration: 100, watchedAt: now, finished: true)]
        for (filter, expected) in [(FolderWatchFilter.unseen, "/a/1.mp4"), (.unfinished, "/a/2.mp4"), (.watched, "/a/3.mp4")] {
            #expect(FolderBrowserModel.filter(rows, search: "", tag: nil, watch: filter, history: history).map(\.path) == [expected])
        }
    }
}
