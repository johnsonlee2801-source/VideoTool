import AppKit
import QuartzCore
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct PlaybackResponsivenessTests {
    @Test("PR1 current-schema writer contention does not block player construction")
    func startupWriter() throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.defaultPath)
        try db.exec("BEGIN IMMEDIATE")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { try? db.exec("ROLLBACK") }
        let start = CACurrentMediaTime()
        let player = PlayerWindowController(); defer { player.shutdown() }
        #expect(CACurrentMediaTime() - start < 0.25)
    }
    @Test("PR2 long transcript queries return control promptly and preserve exact matching")
    func transcriptSearch() async throws {
        let document = SubtitleTranscript(cues: (0..<30000).map { SubtitleCue(start: Double($0)*2, end: Double($0)*2+1.5, text: "A sentence about smooth video playback and subtitle searching number \($0)", translation: "流畅的视频播放与字幕搜索第\($0)句") })
        let view = SubtitleTranscriptView(frame: .zero)
        view.setDocument(document, status: "")
        view.searchField.stringValue = "none none none"
        let start = CACurrentMediaTime(); view.refreshQuery()
        #expect(CACurrentMediaTime() - start < 0.1)
        #expect(await wait { view.rows.isEmpty })
        view.searchField.stringValue = "number 29999"; view.refreshQuery()
        #expect(await wait { view.rows == [29999] })
        view.searchField.stringValue = "流畅的视频播放与字幕搜索第29998句"; view.refreshQuery()
        #expect(await wait { view.rows == [29998] })
    }
    @Test("PR3 progress updates avoid metadata reloads while Recent or transcript is visible")
    func historyRefresh() async throws {
        let suite = "videotool-tests-responsiveness-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent(UUID().uuidString + ".sqlite").path)
        let path = "/performance/episode.mp4"
        _ = try store.addRoot("/performance")
        try store.upsert(MediaRecord(path: path, fileKey: "test", size: 2000, modified: Date(), duration: 1800, width: 1920, height: 1080, root: "/performance"))
        let history = WatchHistoryStore(defaults: defaults)
        let model = LibraryController(store: store, stars: nil, makeIndexer: { nil }, history: history)
        let sidebar = PlayerSidebarView(bookmarks: BookmarkListView(), preferences: nil, history: history,
            networkHistory: NetworkWatchHistoryStore(defaults: defaults), libraryProvider: { model }, onOpen: { _ in })
        defer { sidebar.shutdown() }
        sidebar.show(.recent)
        let previous = model.onChange
        var metadataReloads = 0
        model.onChange = { metadataReloads += 1; previous?() }
        history.recordProgress(path: path, position: 600, duration: 1800)
        try await Task.sleep(for: .milliseconds(250))
        #expect(metadataReloads == 0)
        sidebar.showTranscript()
        history.recordProgress(path: path, position: 610, duration: 1800)
        try await Task.sleep(for: .milliseconds(250))
        #expect(metadataReloads == 0)
        #expect(history.entry(for: path)?.position == 610)
        sidebar.hideTranscript(); sidebar.show(.library)
        #expect(model.items.first?.watch?.position == 610)
    }
    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }
}
