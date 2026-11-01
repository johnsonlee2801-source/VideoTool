import AppKit
import Testing
@testable import VideoTool

@Suite @MainActor struct SubtitleTranscriptViewTests {
    @Test("SV2 compact rows leave room for wrapped original text and its translation")
    func bilingualHeight() throws {
        let view = SubtitleTranscriptView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.setDocument(SubtitleTranscript(cues: [SubtitleCue(start: 1, end: 3, text: "A small detail makes watching easier.", translation: "一个小细节，让观看更便捷。")]), status: "")
        view.layoutSubtreeIfNeeded()
        let cell = try #require(view.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let label = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("watching") })
        let height = (label.stringValue as NSString).boundingRect(with: NSSize(width: label.bounds.width, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: try #require(label.font)]).height
        #expect(label.visibleRect.height + 1 >= height)
    }
    @Test("SV1 native search, row activation and replay controls use timed cues")
    func controls() async throws {
        let view = SubtitleTranscriptView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
        let first = SubtitleCue(start: 1, end: 3, text: "Hello", translation: "你好")
        let second = SubtitleCue(start: 5, end: 8, text: "Second")
        view.setDocument(SubtitleTranscript(cues: [first, second]), status: "")
        view.searchField.stringValue = "SECOND"; view.refreshQuery()
        let deadline = Date().addingTimeInterval(5)
        while view.isSearching && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.rows == [1])
        var selected: SubtitleCue?
        view.onJump = { selected = $0 }
        view.table.selectRowIndexes([0], byExtendingSelection: false)
        NSApp.sendAction(view.table.action!, to: view.table.target, from: view.table)
        #expect(selected == second)
        var replays = 0; view.onReplay = { replays += 1 }
        view.updatePosition(6)
        view.replayButton.performClick(nil)
        #expect(replays == 1)
        view.setDocument(nil, status: "loading")
        #expect(view.rows.isEmpty && !view.replayButton.isEnabled)
    }
}
