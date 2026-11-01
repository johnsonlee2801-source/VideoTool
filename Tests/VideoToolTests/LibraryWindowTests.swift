import AppKit
import Testing
@testable import VideoTool

// Smoke tests for the AppKit library window: it builds, shows the controller's
// sections, renders cards, and opens a double-clicked video.

@Suite @MainActor struct LibraryWindowTests {
    private func makeController(withVideos names: [String]) throws -> (LibraryController, LibraryStore) {
        let db = TestTemp.directory.appendingPathComponent("lw-\(UUID().uuidString).sqlite").path
        let store = try LibraryStore(path: db)
        _ = try store.addRoot("/m")
        for (i, n) in names.enumerated() {
            try store.upsert(MediaRecord(path: "/m/\(n)", fileKey: "k\(i)", size: 1, modified: Date(timeIntervalSince1970: 1_700_000_000),
                                         duration: Double(30 * (i + 1)), width: 1920, height: 1080, root: "/m"))
        }
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil },
                                  background: { _ in }, main: { $0() })
        return (c, store)
    }

    @Test("W1 the grid shows exactly the controller's sections and items") func gridMatchesController() throws {
        let (c, _) = try makeController(withVideos: ["a.mp4", "b.mkv", "c.mov"])
        let w = LibraryTestHost(controller: c, onOpen: { _ in })
        let grid = NSCollectionView()
        #expect(w.numberOfSections(in: grid) == 1)
        #expect(w.collectionView(grid, numberOfItemsInSection: 0) == 3)
        c.mode = .duration
        #expect(w.numberOfSections(in: grid) == c.sections.count)
    }

    @Test("W2 a card renders name, duration, resolution and stars") func card() throws {
        let (c, _) = try makeController(withVideos: ["clip.mp4"])
        var item = try #require(c.items.first)
        item.starCount = 2
        let card = LibraryCardItem()
        card.loadView()
        card.configure(item, thumbnail: URL(fileURLWithPath: "/nonexistent.jpg"))
        let texts = card.textsForTesting
        #expect(texts.contains("clip.mp4"))
        #expect(texts.contains("0:30"))
        #expect(texts.contains("HD"))
        #expect(texts.contains("★ 2"))
    }

    @Test("W3 opening an item hands its file URL to the player") func open() throws {
        let (c, _) = try makeController(withVideos: ["clip.mp4"])
        var opened: URL?
        let w = LibraryTestHost(controller: c, onOpen: { opened = $0 })
        w.openForTesting(section: 0, item: 0)
        #expect(opened == URL(fileURLWithPath: "/m/clip.mp4"))
    }

    @Test("W4 an empty library explains how to start") func emptyState() throws {
        let db = TestTemp.directory.appendingPathComponent("lw-\(UUID().uuidString).sqlite").path
        let c = LibraryController(store: try LibraryStore(path: db), stars: nil, makeIndexer: { nil },
                                  background: { _ in }, main: { $0() })
        let w = LibraryTestHost(controller: c, onOpen: { _ in })
        #expect(w.emptyMessageForTesting.contains("添加文件夹"))
        #expect(w.emptyMessageForTesting.contains("自动整理"))
        #expect(w.emptyMessageForTesting.contains("不会移动"))
    }

    @Test("W5 card width adapts to fill the row: more columns when wider, never narrower than the minimum")
    func adaptiveColumns() {
        let narrow = LibraryCardItem.layout(forWidth: 700)
        let wide = LibraryCardItem.layout(forWidth: 1600)
        #expect(wide.columns > narrow.columns)
        for l in [narrow, wide, LibraryCardItem.layout(forWidth: 300)] {
            #expect(l.itemSize.width >= LibraryCardItem.minWidth || l.columns == 1)
            #expect(abs(l.itemSize.height - (l.itemSize.width * 9 / 16 + LibraryCardItem.infoHeight)) < 0.5, "16:9 thumbnail")
        }
        let w = 1600.0, l = LibraryCardItem.layout(forWidth: w)
        let used = Double(l.columns) * l.itemSize.width + Double(l.columns - 1) * LibraryCardItem.spacing + 2 * LibraryCardItem.sideInset
        #expect(abs(used - w) < 1.5, "the row is filled edge to edge: \(used) vs \(w)")
    }

    @Test("W6 compact row sizing respects the live flow-layout insets during a width transition")
    func compactInsets() throws {
        let (c, _) = try makeController(withVideos: ["a.mp4"])
        let browser = LibraryTestHost(controller: c, onOpen: { _ in })
        browser.window?.setContentSize(NSSize(width: 380, height: 600))
        let grid = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        grid.collectionViewLayout = layout
        let size = browser.collectionView(grid, layout: layout, sizeForItemAt: IndexPath(item: 0, section: 0))
        #expect(size.width <= 256, "the row must fit even before the compact insets have been applied")
    }

    @Test("W7 the library layout re-queries row sizes whenever its viewport width changes")
    func layoutInvalidatesRowMetrics() throws {
        let (c, _) = try makeController(withVideos: ["a.mp4"])
        let browser = LibraryTestHost(controller: c, onOpen: { _ in })
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let grid = browser.gridForTesting
        let layout = try #require(grid.collectionViewLayout as? NSCollectionViewFlowLayout)
        let newBounds = NSRect(x: 0, y: 0, width: max(100, grid.bounds.width - 80), height: grid.bounds.height)
        #expect(layout.shouldInvalidateLayout(forBoundsChange: newBounds))
        let context = try #require(layout.invalidationContext(forBoundsChange: newBounds) as? NSCollectionViewFlowLayoutInvalidationContext)
        #expect(context.invalidateFlowLayoutDelegateMetrics, "cached widths must not survive a sidebar resize")
    }

    @Test("W8 row sizing uses the new scroll viewport even while the collection still reports its old width")
    func shrinkingViewport() throws {
        let (c, _) = try makeController(withVideos: ["a.mp4"])
        let browser = LibraryTestHost(controller: c, onOpen: { _ in })
        browser.window?.setContentSize(NSSize(width: 380, height: 600))
        let grid = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 445, height: 400))
        let flow = NSCollectionViewFlowLayout()
        flow.sectionInset = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        grid.collectionViewLayout = flow
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 275, height: 400))
        scroll.documentView = grid
        grid.setBoundsSize(NSSize(width: 445, height: 400))
        #expect(grid.bounds.width > scroll.contentView.bounds.width)
        let size = browser.collectionView(grid, layout: flow, sizeForItemAt: IndexPath(item: 0, section: 0))
        #expect(size.width <= 255)
    }
}

@Suite(.serialized) @MainActor struct PlayerSidebarTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    private func controller(background: @escaping LibraryController.Executor = { _ in }) throws -> LibraryController {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("sb-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        try store.upsert(MediaRecord(path: "/m/alpha.mp4", fileKey: "sb-alpha", size: 1, modified: Date(),
                                     duration: 100, width: 1920, height: 1080, root: "/m"))
        return LibraryController(store: store, stars: nil,
                                 makeIndexer: { LibraryIndexer(store: store, prober: FakeProber(), tagger: nil) },
                                 background: background, main: { $0() })
    }

    @Test("SB1 the library entry opens the player's sidebar without a separate library window")
    func singleWindowLibraryEntry() throws {
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let app = AppDelegate()
        defer {
            app.playerWindow?.shutdown()
            for window in NSApp.windows where !existing.contains(ObjectIdentifier(window)) {
                window.close()
            }
        }
        app.showLibrary(nil)
        #expect(!NSApp.windows.contains { !existing.contains(ObjectIdentifier($0)) && $0.title == L("视频库") },
                "the library must be inside the player, never a second window")
        let player = try #require(app.playerWindow, "opening the library must create/use the player's window")
        let window = try #require(player.window)
        app.showLibrary(nil)
        #expect(app.playerWindow === player)
        #expect(player.window === window)
    }

    @Test("SB2 all three tabs share one retained sidebar, preserving library search and playback state")
    func tabsKeepState() throws {
        let c = try controller()
        let w = PlayerWindowController(libraryProvider: { c })
        defer { w.shutdown() }
        w.showLibrary(nil)
        let browser = try #require(w.sidebar.libraryBrowser)
        #expect(w.sidebar.tabTitles == [L("视频库"), L("最近播放"), L("星标")])
        browser.searchFieldForTesting.stringValue = "alpha"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.searchFieldForTesting))
        let paused = w.engine?.state.isPaused
        let recentButton = try #require(descendants(w.sidebar).compactMap { $0 as? NSButton }.first { $0.title == L("最近播放") })
        recentButton.performClick(nil)
        #expect(w.sidebar.state.isExpanded && w.sidebar.state.tab == .recent)
        w.toggleBookmarkList(nil)
        #expect(w.sidebar.state.tab == .stars && !w.listPanel.isHidden)
        w.showLibrary(nil)
        #expect(w.sidebar.libraryBrowser === browser && c.search == "alpha")
        #expect(w.engine?.state.isPaused == paused)
    }

    @Test("SB3 resize clamps to the available width and re-expands to the user's preferred width")
    func layoutWidths() throws {
        let w = PlayerWindowController(libraryProvider: { try? controller() })
        defer { w.shutdown() }
        let content = try #require(w.window?.contentView)
        w.window?.setContentSize(NSSize(width: 1280, height: 772))
        w.showLibrary(nil)
        content.layoutSubtreeIfNeeded()
        #expect(abs(w.sidebar.frame.width - 380) < 1)
        w.sidebar.resize(to: 450)
        content.layoutSubtreeIfNeeded()
        #expect(abs(w.sidebar.frame.width - 450) < 1)
        w.window?.setContentSize(NSSize(width: 520, height: 400))
        content.layoutSubtreeIfNeeded()
        #expect(abs(w.sidebar.frame.width - 280) < 1)
        #expect((w.playerView?.frame.width ?? 0) >= 239)
        w.window?.setContentSize(NSSize(width: 1280, height: 772))
        content.layoutSubtreeIfNeeded()
        #expect(abs(w.sidebar.frame.width - 450) < 1)
        w.sidebar.close()
        content.layoutSubtreeIfNeeded()
        #expect(w.sidebar.isHidden && w.sidebar.frame.width == 0)
    }

    @Test("SB4 temporary library failure retries on reopening without replacing the player window")
    func providerRetries() throws {
        let c = try controller()
        var attempts = 0
        let w = PlayerWindowController(libraryProvider: { attempts += 1; return attempts == 1 ? nil : c })
        defer { w.shutdown() }
        let window = w.window
        w.showLibrary(nil)
        #expect(w.sidebar.libraryBrowser == nil && !w.sidebar.errorMessage.isEmpty)
        w.sidebar.resize(to: 400)
        #expect(attempts == 1, "dragging the divider must not repeatedly retry opening the database")
        w.sidebar.close()
        w.showLibrary(nil)
        #expect(w.sidebar.libraryBrowser != nil && w.sidebar.errorMessage.isEmpty)
        #expect(w.window === window && attempts == 2)
    }

    @Test("SB5 a focused library list keeps arrows and Space; player focus still receives player commands")
    func focusOwnsKeys() throws {
        let c = try controller()
        let w = PlayerWindowController(libraryProvider: { c })
        defer { w.shutdown() }
        w.window?.orderBack(nil)
        w.showLibrary(nil)
        let browser = try #require(w.sidebar.libraryBrowser)
        let grid = browser.gridForTesting
        #expect(w.window?.makeFirstResponder(grid) == true)
        func key(_ chars: String, _ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: w.window?.windowNumber ?? 0, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        let right = try key("\u{f703}", 124), space = try key(" ", 49)
        #expect(w.handleKeyDown(right) === right && w.handleKeyDown(space) === space)
        #expect(w.window?.makeFirstResponder(browser.searchFieldForTesting) == true)
        #expect(w.window?.firstResponder is NSText)
        #expect(w.handleKeyDown(space) === space, "typing spaces into search must not pause the video")
        w.window?.makeFirstResponder(w.playerView)
        #expect(w.handleKeyDown(right) == nil)
    }

    @Test("SB6 collapsing or changing tabs does not cancel indexing; player shutdown cancels pending work")
    func indexingLifetime() throws {
        var jobs: [() -> Void] = []
        let c = try controller(background: { jobs.append($0) })
        let w = PlayerWindowController(libraryProvider: { c })
        defer { w.shutdown() }
        w.showLibrary(nil)
        #expect(!c.isIndexing, "opening a sidebar must not start a new filesystem scan")
        c.rescanAll()
        #expect(c.isIndexing && jobs.count == 1)
        w.sidebar.show(.recent); w.sidebar.close()
        #expect(c.isIndexing)
        w.shutdown()
        jobs.forEach { $0() }
        #expect(!c.isIndexing)
    }

    @Test("SB7 recent playback refreshes without changing window focus, and missing files remain recorded")
    func recentRefreshAndMissingFile() async throws {
        let name = "videotool-tests-sidebar-history-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let history = WatchHistoryStore(defaults: d)
        let w = PlayerWindowController(history: history)
        defer { w.shutdown() }
        w.sidebar.show(.recent)
        history.recordOpened(path: "/missing/sidebar-film.mp4", duration: 100)
        for _ in 0..<100 where w.sidebar.recent.rows.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(w.sidebar.recent.rows.map(\.path) == ["/missing/sidebar-film.mp4"])
        w.sidebar.openMedia(URL(fileURLWithPath: "/missing/sidebar-film.mp4"))
        #expect(!w.sidebar.errorMessage.isEmpty)
        #expect(w.loadedPath == nil && history.all.count == 1)
    }

    @Test("SB8 sidebar preferences survive player recreation while search text stays in the session")
    func restorePreferences() throws {
        let name = "videotool-tests-sidebar-restore-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let prefs = PlayerSidebarPreferences(defaults: d)
        let first = PlayerWindowController(sidebarPreferences: prefs)
        first.sidebar.show(.recent); first.sidebar.resize(to: 425)
        first.shutdown()
        let second = PlayerWindowController(sidebarPreferences: prefs)
        defer { second.shutdown() }
        #expect(second.sidebar.state.isExpanded && second.sidebar.state.tab == .recent)
        #expect(second.sidebar.state.preferredWidth == 425)
    }

    @Test("SB9 reopening the library refreshes progress recorded while the sidebar was collapsed")
    func refreshAfterCollapse() throws {
        let suite = "videotool-tests-sidebar-hidden-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let history = WatchHistoryStore(defaults: d)
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("sb9-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        try store.upsert(MediaRecord(path: "/m/a.mp4", fileKey: "sb9", size: 1, modified: Date(), duration: 100,
                                     width: 1920, height: 1080, root: "/m"))
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() }, history: history)
        let w = PlayerWindowController(libraryProvider: { c }, history: history)
        defer { w.shutdown() }
        w.showLibrary(nil)
        #expect(c.sections.map(\.title) == [L("全部视频")])
        w.sidebar.close()
        history.recordProgress(path: "/m/a.mp4", position: 40, duration: 100)
        w.showLibrary(nil)
        #expect(c.sections.map(\.title) == [L("继续观看"), L("全部视频")])
        #expect(c.items.first?.watch?.position == 40)
    }

    @Test("SB10 a metadata refresh keeps the selected video when continue-watching inserts a section")
    func keepSelectionDuringRefresh() throws {
        let suite = "videotool-tests-sidebar-select-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let history = WatchHistoryStore(defaults: d)
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("sb10-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        for name in ["alpha", "beta"] {
            try store.upsert(MediaRecord(path: "/m/\(name).mp4", fileKey: name, size: 1, modified: Date(), duration: 100,
                                         width: 1920, height: 1080, root: "/m"))
        }
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() }, history: history)
        let w = PlayerWindowController(libraryProvider: { c }, history: history)
        defer { w.shutdown() }
        w.showLibrary(nil)
        w.window?.contentView?.layoutSubtreeIfNeeded()
        let browser = try #require(w.sidebar.libraryBrowser)
        let grid = browser.gridForTesting
        grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        history.recordProgress(path: "/m/alpha.mp4", position: 40, duration: 100)
        c.reload()
        #expect(c.sections.map(\.title) == [L("继续观看"), L("全部视频")])
        #expect(grid.selectionIndexPaths == [IndexPath(item: 1, section: 1)], "beta remains selected in the all-videos section")
    }

    @Test("SB11 folder filtering and search combine inside the sidebar and survive switching tabs")
    func folderFilterAndSearch() throws {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("sb11-\(UUID().uuidString).sqlite").path)
        for (root, name) in [("/a", "Alpha"), ("/b", "Beta")] {
            _ = try store.addRoot(root)
            try store.upsert(MediaRecord(path: "\(root)/\(name).mp4", fileKey: name, size: 1, modified: Date(), duration: 100,
                                         width: 1920, height: 1080, root: root))
        }
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() })
        let w = PlayerWindowController(libraryProvider: { c })
        defer { w.shutdown() }
        w.showLibrary(nil)
        let browser = try #require(w.sidebar.libraryBrowser)
        let picker = try #require(descendants(browser.view).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitle(at: 0) == L("所有文件夹") })
        picker.selectItem(at: 1)
        #expect(NSApp.sendAction(try #require(picker.action), to: picker.target, from: picker))
        #expect(browser.selectedRoot == "/a")
        #expect(browser.collectionView(NSCollectionView(), numberOfItemsInSection: 0) == 1)
        c.search = "Beta"
        #expect(browser.numberOfSections(in: NSCollectionView()) == 0)
        w.sidebar.show(.recent); w.showLibrary(nil)
        #expect(browser.selectedRoot == "/a" && c.search == "Beta")
        #expect(try store.media(inRoot: nil).count == 2, "filtering must not alter the index or source paths")
    }
}
