import AppKit
import Speech
import Testing
@testable import VideoTool

// Gaps found by the TDD coverage pass on 2026-10-19 (line coverage had dropped to 83.4%).

struct AppleSpeechErrorTests {
    @Test("CG1 a language this Mac cannot recognise is reported, not crashed on") func unsupportedSpeech() async throws {
        guard #available(macOS 26.0, *) else { return }
        let wav = TestTemp.directory.appendingPathComponent("cg1-\(UUID().uuidString).wav")
        await #expect(throws: AISubtitleError.unsupportedLanguage) {
            try await AppleSpeechRecognizer().transcribe(audio: wav, locale: "xx-ZZ", duration: 1, progress: { _ in })
        }
    }

    @Test("CG2 a language pair the system cannot translate is reported as unavailable") func unsupportedTranslation() async throws {
        guard #available(macOS 26.0, *) else { return }
        let t = AppleTranslator(window: { nil })
        await #expect(throws: AISubtitleError.translationUnavailable) {
            try await t.translate(["Hello."], from: "en", to: "tlh")
        }
    }

    @Test("CG3 the language list is what this Mac supports, English included") func availableSources() async {
        guard #available(macOS 26.0, *) else { return }
        let sources = await AppleSpeechRecognizer.availableSources()
        #expect(sources.contains { $0.id == "en-US" })
        #expect(sources.allSatisfy { s in SubtitleLanguages.sources.contains(s) })
    }

    @Test("CG4 translations go back to their own lines in batches, whatever order they return in") func batching() {
        guard #available(macOS 26.0, *) else { return }
        #expect(AppleTranslator.batches(count: 85, size: 40) == [0..<40, 40..<80, 80..<85])
        #expect(AppleTranslator.batches(count: 0, size: 40).isEmpty)
        let merged = AppleTranslator.merge([("2", "丙"), ("0", "甲"), (nil, "?"), ("9", "超出")], into: ["a", "b", "c"])
        #expect(merged == ["甲", "b", "丙"])
    }
}

@Suite(.serialized) @MainActor struct SeriesEditFormTests {
    @Test("CG5 the form starts from what the series view shows") func prefilled() {
        let f = SeriesEditDialog.Form(current: EpisodeInfo(title: "繁花", season: 2, episode: 7, strong: true))
        #expect(f.title.stringValue == "繁花" && f.season.stringValue == "2" && f.episode.stringValue == "7")
        #expect(f.renameAll.state == .on)
        let empty = SeriesEditDialog.Form(current: nil)
        #expect(empty.title.stringValue.isEmpty && empty.episode.stringValue.isEmpty)
    }

    @Test("CG6 save / not a series / cancel, and an unusable form saves nothing") func results() {
        let f = SeriesEditDialog.Form(current: EpisodeInfo(title: "繁花", season: nil, episode: 7, strong: true))
        #expect(f.result(for: .alertFirstButtonReturn) == .save(SeriesOverride(title: "繁花", season: nil, episode: 7), renameShow: true))
        f.renameAll.state = .off
        #expect(f.result(for: .alertFirstButtonReturn) == .save(SeriesOverride(title: "繁花", season: nil, episode: 7), renameShow: false))
        #expect(f.result(for: .alertThirdButtonReturn) == .notSeries)
        #expect(f.result(for: .alertSecondButtonReturn) == .cancel)
        f.episode.stringValue = "七"
        #expect(f.result(for: .alertFirstButtonReturn) == .cancel)
    }
}

@Suite(.serialized) @MainActor struct AppMenuTests {
    private var main: NSMenu? { NSApp.mainMenu }
    private func item(_ menu: String, _ title: String) -> NSMenuItem? {
        main?.items.first { $0.submenu?.title == menu }?.submenu?.items.first { $0.title == title }
    }

    @Test("CG7 the menus offer the new features with the right keys") func menus() throws {
        let ai = try #require(item("播放", "AI 字幕…"))
        #expect(ai.keyEquivalent == "t" && ai.action == #selector(PlayerWindowController.generateAISubtitles(_:)))
        let speeds = try #require(item("播放", "播放速度")?.submenu)
        #expect(speeds.items.map(\.title) == PlaybackSpeed.presets.map(PlaybackSpeed.label))
        #expect(item("播放", "声音输出")?.submenu?.delegate != nil)
        #expect(item("帮助", "发送反馈…") != nil)
        #expect(item("文件", "打开视频时询问加入视频库") != nil)
    }

    @Test("CG8 the sound output submenu is filled from the player when opened") func outputMenu() throws {
        let menu = try #require(item("播放", "声音输出")?.submenu)
        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(menu.items.first?.title == "跟随系统", "the test host has a player window")
        #expect(menu.items.filter { $0.state == .on }.count == 1)
    }

    @Test("CG9 'ask to add folders' can be switched off and on from the File menu") func offerToggle() throws {
        let toggle = try #require(item("文件", "打开视频时询问加入视频库"))
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let prefs = LibraryOfferPreferences()
        let before = prefs.neverAsk
        defer { prefs.neverAsk = before }
        prefs.neverAsk = false
        _ = delegate.validateMenuItem(toggle)
        #expect(toggle.state == .on)
        NSApp.sendAction(toggle.action!, to: delegate, from: toggle)
        #expect(prefs.neverAsk)
        _ = delegate.validateMenuItem(toggle)
        #expect(toggle.state == .off)
    }
}
