import AppKit
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct AISubtitleUITests {
    @Test("AU1 the dialog starts at the last choice and reads back what is picked, incl. 'don't translate'")
    func dialogChoices() {
        let p = AISubtitleDialog.popups(sources: SubtitleLanguages.sources, source: "ja-JP", target: "zh-Hant")
        #expect(p.source.titleOfSelectedItem == "日语")
        #expect(p.target.titleOfSelectedItem == "繁體中文")
        #expect(AISubtitleDialog.choice(from: p) == .init(source: "ja-JP", target: "zh-Hant"))
        p.target.selectItem(withTitle: "不翻译（只要原文）")
        #expect(AISubtitleDialog.choice(from: p) == .init(source: "ja-JP", target: nil))
        let none = AISubtitleDialog.popups(sources: SubtitleLanguages.sources, source: "en-US", target: nil)
        #expect(none.target.titleOfSelectedItem == "不翻译（只要原文）")
    }

    @Test("AU2 the card's bar moves forward through the phases; the result line has no bar and no cancel")
    func cardProgress() {
        let card = AISubtitleCard()
        var last = -1.0
        for (phase, f) in [(AISubtitlePipeline.Phase.extracting, 0.0), (.extracting, 1), (.recognizing, 0.5),
                           (.recognizing, 1), (.translating, 0.5), (.done, 1)] {
            card.show(phase, f)
            #expect(card.fraction >= last)
            last = card.fraction
        }
        #expect(card.fraction == 1 && card.isCancellable && !card.isHidden)
        card.finish("字幕已生成，共 12 句")
        #expect(card.message == "字幕已生成，共 12 句" && !card.isCancellable)
        card.hide()
        #expect(card.isHidden)
    }

    @Test("AU3 cancel on the card reaches the window") func cardCancel() {
        let card = AISubtitleCard()
        var cancelled = false
        card.onCancel = { cancelled = true }
        card.show(.recognizing, 0.3)
        card.onCancel?()
        #expect(cancelled)
    }

    @Test("AU4 the subtitle track is named after its languages") func titles() {
        #expect(PlayerWindowController.subtitleTitle(.init(video: "/v", source: "en-US", target: "zh-Hans"), translated: true)
                == "AI 字幕（英语 → 简体中文）")
        #expect(PlayerWindowController.subtitleTitle(.init(video: "/v", source: "ja-JP", target: "zh-Hans"), translated: false)
                == "AI 字幕（日语）")
    }

    @Test("AU5 snapshot: the card while listening, and its result line") func snapshot() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        w.stageForSnapshot(frame: Snapshot.frame(at: 6), bookmarks: [], duration: 1500, position: 30,
                           showList: false, previewFirst: false, hud: nil)
        w.aiCard.show(.recognizing, 0.45)
        try Snapshot.write(try #require(w.window?.contentView), "P5-player-ai-subtitles")
        w.aiCard.finish("字幕已生成，共 128 句（按 S 可切换字幕）")
        try Snapshot.write(try #require(w.window?.contentView), "P5b-player-ai-subtitles-done")
    }
}
