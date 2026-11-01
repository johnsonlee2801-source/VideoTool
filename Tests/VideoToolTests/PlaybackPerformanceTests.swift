import AppKit
import QuartzCore
import Testing
@testable import VideoTool

/// Controlled Release measurements only; normal offline gates skip this suite.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VIDEOTOOL_PERFORMANCE"] == "1")) @MainActor struct PlaybackPerformanceTests {
    @Test("PP1 writer contention, maximum transcript and large history retain a responsive main thread")
    func responsiveness() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.defaultPath)
        try db.exec("BEGIN IMMEDIATE")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { try? db.exec("ROLLBACK") }
        var start = CACurrentMediaTime()
        let player = PlayerWindowController()
        let startup = (CACurrentMediaTime()-start)*1000
        print("PERF writer-startup-ms: \(startup)")
        player.shutdown(); #expect(startup < 100)
        try await Task.sleep(for: .milliseconds(700))
        let document = SubtitleTranscript(cues: (0..<30000).map { SubtitleCue(start: Double($0)*2, end: Double($0)*2+1.5, text: "A sentence about smooth video playback and subtitle searching number \($0)", translation: "流畅的视频播放与字幕搜索第\($0)句") })
        let view = SubtitleTranscriptView(frame: .zero); view.setDocument(document, status: "")
        var latencies: [Double] = []
        let searchGap = try await heartbeat {
            for query in ["smooth", "不存在的关键词", "number 29999", "流畅的视频", "searching", "none none none"] {
                view.searchField.stringValue = query; start = CACurrentMediaTime(); view.refreshQuery()
                latencies.append((CACurrentMediaTime()-start)*1000)
                while view.isSearching { try await Task.sleep(for: .milliseconds(10)) }
            }
        }
        print("PERF transcript-30000-input-ms: \(latencies) main-gap-ms: \(searchGap)")
        #expect((latencies.max() ?? 0) < 100 && searchGap < 100)
        let suite = "videotool-tests-large-progress-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let directory = TestTemp.directory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("library.sqlite").path
        let database = try SQLiteDatabase(path: path), store = try LibraryStore(path: path)
        _ = try store.addRoot(directory.path)
        try database.run("""
            WITH RECURSIVE entries(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM entries WHERE n < 10000)
            INSERT INTO media(path,file_key,size,mtime,duration,width,height,root,scanned_at,status,attempts,content_check)
            SELECT ? || '/' || printf('%05d.mp4',n), 'key-' || n, 2000000, 0, 1800, 1920, 1080, ?, 0, 'ok', 0, '' FROM entries
            """, [.text(directory.path), .text(directory.path)])
        var historyRows: [String: [String: Double]] = [:]
        for i in 1...2000 { historyRows[directory.appendingPathComponent(String(format: "%05d.mp4", i)).path] = ["p":600,"d":1800,"t":Double(i),"f":0] }
        defaults.set(historyRows, forKey: WatchHistoryStore.defaultKey)
        let history = WatchHistoryStore(defaults: defaults), model = LibraryController(store: store, stars: nil, makeIndexer: { nil }, history: WatchHistoryStore(defaults: defaults))
        let sidebar = PlayerSidebarView(bookmarks: BookmarkListView(), preferences: nil, history: history, networkHistory: NetworkWatchHistoryStore(defaults: defaults), libraryProvider: { model }, onOpen: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sidebar
        defer { sidebar.shutdown(); window.orderOut(nil) }
        sidebar.show(.recent); sidebar.layoutSubtreeIfNeeded()
        let original = model.onChange; var metadataReloads = 0
        model.onChange = { metadataReloads += 1; original?() }
        let progressGap = try await heartbeat {
            history.recordProgress(path: directory.appendingPathComponent("00001.mp4").path, position: 605, duration: 1800)
            try await Task.sleep(for: .milliseconds(800))
        }
        sidebar.showTranscript()
        let hiddenGap = try await heartbeat {
            history.recordProgress(path: directory.appendingPathComponent("00001.mp4").path, position: 610, duration: 1800)
            try await Task.sleep(for: .milliseconds(500))
        }
        print("PERF library-10000-history-2000: visible-main-gap-ms=\(progressGap) hidden-main-gap-ms=\(hiddenGap) metadata-reloads=\(metadataReloads)")
        #expect(progressGap < 100 && hiddenGap < 100 && metadataReloads == 0)
    }
    private func heartbeat(_ work: () async throws -> Void) async throws -> Double {
        var last = CACurrentMediaTime(), maximum = 0.0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { let now = CACurrentMediaTime(); maximum = max(maximum, now-last); last = now }
        timer.resume(); defer { timer.cancel() }
        try await work()
        return maximum*1000
    }
}
