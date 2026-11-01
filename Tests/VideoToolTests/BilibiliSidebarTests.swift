import AppKit
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct BilibiliSidebarTests {
    @Test("BS1 multi-part selection stays compact in the right sidebar and never auto-advances")
    func parts() throws {
        let sidebar = PlayerSidebarView(bookmarks: BookmarkListView(), preferences: nil, history: WatchHistoryStore(), libraryProvider: { nil }, onOpen: { _ in })
        defer { sidebar.shutdown() }
        var selected: [Int] = []
        sidebar.setNetworkParts([BilibiliPart(page: 1, title: "第一集"), BilibiliPart(page: 2, title: "第二集")], current: 1) { selected.append($0) }
        #expect(sidebar.networkPartButtons.count == 2)
        #expect(sidebar.networkPartButtons[0].state == .on)
        #expect(selected.isEmpty)
        sidebar.networkPartButtons[1].performClick(nil)
        #expect(selected == [2])
        sidebar.networkPartButtons[0].performClick(nil)
        #expect(selected == [2], "current part must not restart")
        sidebar.setNetworkParts([], current: 0, onSelect: nil)
        #expect(sidebar.networkPartButtons.isEmpty)
    }
}
