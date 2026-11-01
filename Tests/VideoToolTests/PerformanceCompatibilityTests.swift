import AppKit
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct PerformanceCompatibilityTests {
    @Test("PC1 watch refresh retains indexed metadata until a real metadata reload")
    func cachedMetadata() throws {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent(UUID().uuidString + ".sqlite").path)
        let path = "/performance/episode.mp4"
        try store.upsert(MediaRecord(path: path, fileKey: "k", size: 2000, modified: Date(), duration: 1800, width: 1920, height: 1080, root: "/performance"))
        let history = WatchHistoryStore(key: "performance-" + UUID().uuidString)
        let model = LibraryController(store: store, stars: nil, makeIndexer: { nil }, history: history)
        try store.setTags([("旅行", 1)], for: "k", source: "test")
        history.recordProgress(path: path, position: 120, duration: 1800)
        var changes = 0; model.onChange = { changes += 1 }
        model.refreshWatchHistory()
        #expect(changes == 0 && model.items.first?.tags.isEmpty == true)
        #expect(model.items.first?.watch?.position == 120 && model.items.first?.record.width == 1920)
        model.reload()
        #expect(changes == 1 && model.items.first?.tags == ["旅行"])
    }
    @Test("PC2 visible watch filters and deferred metadata still update without losing selection/search")
    func visibleAndDeferred() async throws {
        let root = TestTemp.directory.appendingPathComponent("compat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("episode.mp4"); try Data([1]).write(to: file)
        let store = try LibraryStore(path: root.appendingPathComponent("library.sqlite").path)
        _ = try store.addRoot(root.path)
        try store.upsert(MediaRecord(path: file.path, fileKey: "k", size: 1, modified: Date(), duration: 1800, width: 1920, height: 1080, root: root.path))
        let history = WatchHistoryStore(key: "compat-" + UUID().uuidString)
        let model = LibraryController(store: store, stars: nil, makeIndexer: { nil }, history: history)
        let sidebar = PlayerSidebarView(bookmarks: BookmarkListView(), preferences: nil, history: history,
            libraryProvider: { model }, onOpen: { _ in })
        defer { sidebar.shutdown() }
        sidebar.show(.library)
        let folders = try #require(sidebar.libraryBrowser?.folderBrowser)
        folders.enter(root.path); folders.searchField.stringValue = "episode"
        folders.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        folders.table.selectRowIndexes([0], byExtendingSelection: false)
        history.recordProgress(path: file.path, position: 600, duration: 1800)
        #expect(await wait { folders.visibleVideos.first?.watch?.position == 600 })
        #expect(folders.table.selectedRow == 0 && folders.searchField.stringValue == "episode")
        let unfinished = try #require(folders.filterMenu().item(withTitle: L("继续观看")))
        NSApp.sendAction(try #require(unfinished.action), to: unfinished.target, from: unfinished)
        history.markFinished(path: file.path, duration: 1800)
        #expect(await wait { folders.visibleVideos.isEmpty })
        sidebar.showTranscript()
        try store.setTags([("旅行", 1)], for: "k", source: "test")
        sidebar.refreshMetadata()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.items.first?.tags.isEmpty == true)
        sidebar.hideTranscript()
        #expect(model.items.first?.tags == ["旅行"] && FileManager.default.fileExists(atPath: file.path))
    }
    @Test("PC3 old query/document completions cannot replace current results or activate old rows")
    func staleSearch() throws {
        let view = SubtitleTranscriptView(frame: .zero), search = DelayedSubtitleSearch()
        view.searcher = search
        let document = SubtitleTranscript(cues: [SubtitleCue(start: 1, end: 3, text: "first"), SubtitleCue(start: 5, end: 8, text: "second")])
        view.setDocument(document, status: "")
        var jumps = 0; view.onJump = { _ in jumps += 1 }
        view.searchField.stringValue = "first"; view.refreshQuery()
        view.searchField.stringValue = "second"; view.refreshQuery()
        search.completions[0]([0])
        #expect(view.rows.isEmpty && view.isSearching)
        NSApp.sendAction(try #require(view.table.action), to: view.table.target, from: view.table)
        #expect(jumps == 0)
        search.completions[1]([1])
        #expect(view.rows == [1] && !view.isSearching)
        view.searchField.stringValue = "again"; view.refreshQuery()
        view.setDocument(nil, status: "new video")
        search.completions[2]([0])
        #expect(view.rows.isEmpty && view.document == nil && !view.isSearching)
    }
    @Test("PC4 the real worker publishes only the latest search and honours cancellation")
    func workerCancellation() async throws {
        let document = SubtitleTranscript(cues: [SubtitleCue(start: 1, end: 3, text: "first"), SubtitleCue(start: 5, end: 8, text: "second")])
        let search = SubtitleSearch()
        var stale = 0, latest: [Int]?
        search.search(document, query: "first") { _ in stale += 1 }
        search.search(document, query: "second") { latest = $0 }
        #expect(await wait { latest != nil })
        #expect(latest == [1] && stale == 0)
        search.search(document, query: "first") { _ in stale += 1 }; search.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(stale == 0)
    }
    @Test("PC5 first library opening applies progress collected while its browser did not exist")
    func firstOpenHistory() throws {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent(UUID().uuidString + ".sqlite").path)
        let path = "/performance/first.mp4"
        try store.upsert(MediaRecord(path: path, fileKey: "first", size: 1, modified: Date(), duration: 1800, width: 1920, height: 1080, root: "/performance"))
        let history = WatchHistoryStore(key: "first-open-" + UUID().uuidString)
        let model = LibraryController(store: store, stars: nil, makeIndexer: { nil }, history: history)
        let sidebar = PlayerSidebarView(bookmarks: BookmarkListView(), preferences: nil, history: history, libraryProvider: { model }, onOpen: { _ in })
        defer { sidebar.shutdown() }
        #expect(sidebar.libraryBrowser == nil)
        history.recordProgress(path: path, position: 600, duration: 1800)
        sidebar.show(.library)
        #expect(model.items.first?.watch?.position == 600)
    }
    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }
}
private final class DelayedSubtitleSearch: SubtitleSearching {
    var completions: [([Int]) -> Void] = []
    func search(_ document: SubtitleTranscript, query: String, completion: @escaping ([Int]) -> Void) { completions.append(completion) }
    func cancel() {}
}
