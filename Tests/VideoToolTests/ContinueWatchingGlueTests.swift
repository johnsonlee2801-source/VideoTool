import AppKit
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct ContinueWatchingGlueTests {
    @Test("CW7 row actions keep stable identity across refresh and native removal removes only history")
    func rowIdentity() throws {
        let name = "videotool-tests-continue-row-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var time = 10.0
        let store = NetworkWatchHistoryStore(defaults: defaults, now: { Date(timeIntervalSince1970: time) })
        let first = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        let second = try NetworkVideo("https://bilibili.com/video/BV1bK411W797")
        store.record(first, title: "one", position: 12, duration: 100)
        var opened: [String] = []
        let list = NetworkHistoryView(store: store) { opened.append($0.video.key); _ = $1 }
        list.refresh(search: "")
        let oldButton = try #require(list.playButtons.first)
        time = 20; store.record(second, title: "two", position: 20, duration: 100)
        list.refresh(search: "")
        oldButton.performClick(nil)
        #expect(opened == [first.key], "reordering must not redirect a queued row action")
        store.remove(first.key); list.refresh(search: "")
        oldButton.performClick(nil)
        #expect(opened == [first.key])
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let remove = try #require(buttons(list).first { $0.title == L("移除记录") })
        remove.performClick(nil)
        #expect(store.entries.isEmpty)
    }
    @Test("CW3 native continue/restart buttons and separate network/local searches preserve intent")
    func controls() throws {
        let name = "videotool-tests-continue-ui-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let local = WatchHistoryStore(defaults: defaults, now: { Date(timeIntervalSince1970: 10) })
        let network = NetworkWatchHistoryStore(defaults: defaults, now: { Date(timeIntervalSince1970: 20) })
        let video = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        network.record(video, title: "Lecture", position: 24, duration: 100)
        var opened: [(URL, Bool)] = []
        let sidebar = PlayerSidebarView(bookmarks: BookmarkListView(), preferences: nil, history: local, networkHistory: network,
            onContinue: { opened.append(($0.url, $1)) }, libraryProvider: { nil }, onOpen: { _ in })
        defer { sidebar.shutdown() }
        sidebar.show(.recent)
        #expect(sidebar.continueBar.item?.url == video.url)
        sidebar.continueBar.resumeButton.performClick(nil)
        sidebar.continueBar.restartButton.performClick(nil)
        #expect(opened.count == 2 && !opened[0].1 && opened[1].1)
        let recent = sidebar.recent
        recent.searchField.stringValue = "local-only"
        recent.sourceSelector.selectedSegment = 1
        NSApp.sendAction(recent.sourceSelector.action!, to: recent.sourceSelector.target, from: recent.sourceSelector)
        #expect(recent.searchField.stringValue.isEmpty)
        recent.searchField.stringValue = "Lecture"
        recent.sourceSelector.selectedSegment = 0
        NSApp.sendAction(recent.sourceSelector.action!, to: recent.sourceSelector.target, from: recent.sourceSelector)
        #expect(recent.searchField.stringValue == "local-only")
        recent.sourceSelector.selectedSegment = 1
        NSApp.sendAction(recent.sourceSelector.action!, to: recent.sourceSelector.target, from: recent.sourceSelector)
        #expect(recent.searchField.stringValue == "Lecture")
        let networkView = try #require(recent.networkView)
        #expect(networkView.entries.count == 1)
        networkView.playButtons[0].performClick(nil)
        #expect(opened.count == 3 && opened.last?.0 == video.url)
    }
}
