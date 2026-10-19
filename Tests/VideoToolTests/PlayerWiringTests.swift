import AppKit
import Testing
@testable import VideoTool

// The player window's wiring of features added 2026-10-18/19, driven with the
// real engine: cached AI subtitles come back, menus reflect and change state.
private final class Marker {}
private let sample = URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: "testsrc-20s", ofType: "mp4")!)

@MainActor
private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite(.serialized) @MainActor struct PlayerWiringTests {
    private func cue(_ text: String) -> String { SRT.document([SubtitleCue(start: 0, end: 30, text: text)]) }

    private func writeCache(source: String, target: String?, text: String) throws -> URL {
        let url = SubtitleCache.url(forVideo: sample.path, source: source, target: target)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cue(text).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("PW1 reopening a video brings back its AI subtitles (translated version preferred)") func cachedTranslated() async throws {
        let prefs = AISubtitlePreferences()
        prefs.source = "en-US"; prefs.target = "zh-Hans"
        let translated = try writeCache(source: "en-US", target: "zh-Hans", text: "大家好。")
        let original = try writeCache(source: "en-US", target: nil, text: "Hello.")
        defer { [translated, original].forEach { try? FileManager.default.removeItem(at: $0) } }
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.trackCounts().subtitle == 1 }, "no subtitle track was added")
        #expect(engine.property("current-tracks/sub/title") == "AI 字幕（英语 → 简体中文）")
    }

    @Test("PW2 without a translated file, the original-only subtitles are used") func cachedOriginalOnly() async throws {
        let prefs = AISubtitlePreferences()
        prefs.source = "en-US"; prefs.target = "zh-Hans"
        let original = try writeCache(source: "en-US", target: nil, text: "Hello.")
        defer { try? FileManager.default.removeItem(at: original) }
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.trackCounts().subtitle == 1 })
        #expect(engine.property("current-tracks/sub/title") == "AI 字幕（英语）")
    }

    @Test("PW3 no cached subtitles: nothing is added") func noCache() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.state.duration > 0 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.trackCounts().subtitle == 0)
    }

    @Test("PW4 the speed menu item sets and remembers the speed; the menu ticks it") func speedMenu() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let item = NSMenuItem(title: "1.5×", action: #selector(PlayerWindowController.chooseSpeedPreset(_:)), keyEquivalent: "")
        item.representedObject = 1.5
        w.chooseSpeedPreset(item)
        #expect(w.preferredSpeed == 1.5)
        #expect(w.validateMenuItem(item) && item.state == .on)
        let other = NSMenuItem(title: "2.0×", action: #selector(PlayerWindowController.chooseSpeedPreset(_:)), keyEquivalent: "")
        other.representedObject = 2.0
        _ = w.validateMenuItem(other)
        #expect(other.state == .off)
        w.perform(.resetSpeed)
    }

    @Test("PW5 the sound output menu lists this Mac's outputs and choosing one is remembered") func audioMenu() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let items = w.audioOutputItems()
        #expect(items.first?.title == "跟随系统" && items.count >= 2)
        #expect(items.filter { $0.state == .on }.count == 1)
        let speaker = items[1]
        w.chooseAudioOutput(speaker)
        #expect(AudioOutputPreference().device == speaker.representedObject as? String)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.property("audio-device") == speaker.representedObject as? String })
        w.chooseAudioOutput(items[0])
        #expect(AudioOutputPreference().device == "auto")
    }

    @Test("PW6 'AI 字幕…' is offered only with a local file open and nothing running") func aiMenuState() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let item = NSMenuItem(title: "AI 字幕…", action: #selector(PlayerWindowController.generateAISubtitles(_:)), keyEquivalent: "")
        #expect(!w.validateMenuItem(item), "no file open")
        w.open(sample)
        if #available(macOS 26.0, *) { #expect(w.validateMenuItem(item)) } else { #expect(!w.validateMenuItem(item)) }
    }

    @Test("PW7 cancelling with nothing running shows nothing and changes nothing") func cancelIdle() {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.cancelAISubtitles(showing: "已取消")
        #expect(w.aiCard.isHidden && !w.isMakingAISubtitles)
    }
}
