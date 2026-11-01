import Foundation
import Testing
@testable import VideoTool

@Suite @MainActor struct NetworkWatchHistoryTests {
    @Test("CW1 network records persist canonical identities, isolate parts and never store share parameters")
    func networkRecords() throws {
        let name = "videotool-tests-network-history-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NetworkWatchHistoryStore(defaults: defaults)
        let p1 = try NetworkVideo("https://bilibili.com/video/BV1bK411W797?p=1&t=12&share_source=ignored")
        let p2 = try p1.selecting(page: 2)
        store.record(p1, title: "First", position: 12, duration: 100)
        store.record(p2, title: "Second", position: 24, duration: 100)
        let reopened = NetworkWatchHistoryStore(defaults: defaults)
        #expect(reopened.entries.count == 2)
        #expect(reopened.entries.first?.video.key == p2.key)
        #expect(reopened.entries.first?.position == 24)
        #expect(reopened.entries.allSatisfy { !$0.video.url.absoluteString.contains("share_source") && $0.video.start == nil })
        store.remove(p1.key)
        #expect(store.entries.map { $0.video.key } == [p2.key])
        store.clear(); #expect(store.entries.isEmpty)
    }
    @Test("CW5 history stays bounded, rejects unresolved IDs and invalid progress")
    func limits() throws {
        let name = "videotool-tests-history-limit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NetworkWatchHistoryStore(defaults: defaults, maxEntries: 1, now: { Date(timeIntervalSince1970: 10) })
        let first = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        let second = try NetworkVideo("https://bilibili.com/video/BV1bK411W797")
        store.record(first, title: "First", position: 10, duration: 100)
        store.record(second, title: "Second", position: 20, duration: 100)
        store.record(try NetworkVideo("https://b23.tv/abc"), title: "unresolved", position: 1, duration: 100)
        store.record(first, title: "invalid", position: .nan, duration: 100)
        #expect(store.entries.map { $0.video.key } == [second.key])
    }
    @Test("CW2 most recent resumable item is selected across separate histories, excluding finished videos")
    func latest() throws {
        let video = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        let local = ["/tmp/episode1.mp4": WatchEntry(position: 20, duration: 100, watchedAt: Date(timeIntervalSince1970: 20), finished: false)]
        let network = NetworkWatchEntry(video: video, title: "Lecture", position: 40, duration: 100, watchedAt: Date(timeIntervalSince1970: 30), finished: false)
        #expect(ContinueWatchingItem.latest(local: local, network: [network])?.url == video.url)
        var finished = network; finished.finished = true
        #expect(ContinueWatchingItem.latest(local: local, network: [finished])?.url.isFileURL == true)
        #expect(ContinueWatchingItem.latest(local: [:], network: [finished]) == nil)
    }
}
