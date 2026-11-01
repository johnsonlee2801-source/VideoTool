import Foundation
import Testing
@testable import VideoTool

@Suite @MainActor struct RecentPlaybackTests {
    private func watch(_ t: Double, _ p: Double = 20) -> WatchEntry {
        WatchEntry(position: p, duration: 100, watchedAt: Date(timeIntervalSince1970: t), finished: false)
    }

    @Test("RH1 recent playback includes unindexed and unavailable paths, sorted newest first with stable ties")
    func unindexedRows() {
        let rows = RecentPlayback.items(history: ["/missing/last.mp4": watch(30), "/m/b.mp4": watch(20),
                                                  "/m/a.mp4": watch(20)], indexed: [])
        #expect(rows.map(\.path) == ["/missing/last.mp4", "/m/a.mp4", "/m/b.mp4"])
        #expect(rows.allSatisfy { $0.indexed == nil })
        #expect(rows.first?.watch.position == 20)
    }

    @Test("RH2 indexed rows retain tags and searches use names or localized tags without manufacturing history")
    func indexedRows() {
        let record = MediaRecord(path: "/m/Cat.mp4", fileKey: "cat", size: 1, modified: .distantPast,
                                 duration: 100, width: 1920, height: 1080, root: "/m")
        let indexed = [LibraryItem(record: record, tags: ["猫"], starCount: 2)]
        let history = ["/m/Cat.mp4": watch(10)]
        #expect(RecentPlayback.items(history: history, indexed: indexed).first?.indexed?.starCount == 2)
        #expect(RecentPlayback.items(history: history, indexed: indexed, search: "Cat").count == 1)
        #expect(RecentPlayback.items(history: history, indexed: indexed, search: "猫").count == 1)
        #expect(RecentPlayback.items(history: history, indexed: indexed, search: "no-match").isEmpty)
        #expect(RecentPlayback.items(history: [:], indexed: indexed).isEmpty)
    }

    @Test("RH3 opening records the time immediately without resetting existing progress or completion")
    func recordOpen() throws {
        let name = "videotool-recent-open-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 10)
        let h = WatchHistoryStore(defaults: d, now: { now })
        h.recordOpened(path: "/m/new.mp4", duration: 100)
        #expect(h.entry(for: "/m/new.mp4")?.position == 0)
        #expect(h.entry(for: "/m/new.mp4")?.watchedAt == now)
        h.recordProgress(path: "/m/old.mp4", position: 40, duration: 100)
        now = Date(timeIntervalSince1970: 20)
        h.recordOpened(path: "/m/old.mp4", duration: 100)
        #expect(h.entry(for: "/m/old.mp4")?.position == 40)
        #expect(h.entry(for: "/m/old.mp4")?.watchedAt == now)
        h.markFinished(path: "/m/old.mp4", duration: 100)
        now = Date(timeIntervalSince1970: 30)
        h.recordOpened(path: "/m/old.mp4", duration: 100)
        #expect(h.entry(for: "/m/old.mp4")?.finished == true)
    }

    @Test("RH4 changes notify the embedded browser after writing, with the defaults scope attached")
    func notifications() throws {
        let name = "videotool-recent-notice-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let h = WatchHistoryStore(defaults: d)
        final class Observed: @unchecked Sendable { var written = false; var count = 0 }
        let observed = Observed()
        let token = NotificationCenter.default.addObserver(forName: WatchHistoryStore.didChange, object: d, queue: nil) { notification in
            observed.count += 1
            observed.written = (notification.object as? UserDefaults)?.dictionary(forKey: WatchHistoryStore.defaultKey)?["/m/a.mp4"] != nil
        }
        defer { NotificationCenter.default.removeObserver(token) }
        h.recordProgress(path: "/m/a.mp4", position: 5, duration: 100)
        #expect(observed.count == 1 && observed.written)
    }
}
