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

@Suite(.serialized) @MainActor struct AISubtitleButtonTests {
    // 2026-10-19: the user could not find AI subtitles (menu + ⌘T only). A button
    // in the control bar makes them visible.
    @Test("PW8 the control bar has an AI subtitles button: off without a video, opens the dialog with one")
    func button() async throws {
        let w = PlayerWindowController()
        defer { w.window?.attachedSheet.map { w.window?.endSheet($0) }; w.shutdown() }
        w.showWindow(nil)
        #expect(w.aiButton.superview != nil, "the button is in the control bar")
        #expect(!w.aiButton.isEnabled, "nothing to subtitle yet")
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.state.duration > 0 })
        guard #available(macOS 26.0, *) else { #expect(!w.aiButton.isEnabled); return }
        #expect(w.aiButton.isEnabled)
        w.aiButton.performClick(nil)
        #expect(await waitUntil(8) { w.window?.attachedSheet != nil }, "clicking the button opens the language dialog")
        #expect(!w.aiButton.isEnabled, "no second dialog while one is open")
    }
}


// Full-codebase audit 2026-10-20 (batches 06, 07).
@Suite(.serialized) @MainActor struct PlayerAuditTests {
    private func copy(_ name: String) throws -> URL {
        let dir = TestTemp.directory.appendingPathComponent("pa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: sample, to: url)
        return url
    }

    @Test("PA1 a key the player handles is consumed: it does not also reach the focused control")
    func keyConsumed() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: w.window?.windowNumber ?? 0, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        #expect(PlayerWindowController.keyMonitorResult(w, space) == nil)
        #expect(PlayerWindowController.keyMonitorResult(nil, space) === space, "window gone: pass the key on")
    }

    @Test("PA2 a late 'file loaded' for the previous file is ignored")
    func staleFileLoaded() async throws {
        let a = try copy("a.mp4"), b = try copy("b.mp4")
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(b)
        let engine = try #require(w.engine)
        #expect(await waitUntil { w.loadedPath == b.path })
        engine.onEvent?(.fileLoaded(path: a.path, duration: 20))      // queued before the switch, delivered after
        #expect(w.loadedPath == b.path)
    }

    @Test("PA3 choosing the AI subtitles after having turned subtitles off is remembered")
    func aiChoiceRemembered() async throws {
        let video = try copy("talk.mp4")
        let prefs = AISubtitlePreferences()
        prefs.source = "en-US"; prefs.target = nil
        let srt = SubtitleCache.url(forVideo: video.path, source: "en-US", target: nil)
        try FileManager.default.createDirectory(at: srt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "Hello.")]).write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }
        PlaybackMemory().update(video.path) { $0.subtitleTrack = "no" }   // earlier: subtitles off
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(video)
        let engine = try #require(w.engine)
        #expect(await waitUntil { w.loadedPath == video.path && engine.trackCounts().subtitle == 1 })
        #expect(await waitUntil { engine.property("sid") == "no" }, "the earlier choice is respected")
        _ = w.handleKeyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: w.window?.windowNumber ?? 0, context: nil, characters: "s",
                                             charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!)
        #expect(await waitUntil { engine.property("sid") != "no" })
        #expect(await waitUntil { PlaybackMemory().entry(for: video.path)?.subtitleTrack == nil },
                "AI subtitles chosen: no override left to switch them off next time")
    }

    @Test("PA4 exporting AI subtitles onto an existing file replaces it; onto the cache itself changes nothing")
    func subtitleExportReplace() async throws {
        let video = try copy("e.mp4")
        let prefs = AISubtitlePreferences()
        prefs.source = "en-US"; prefs.target = nil
        let srt = SubtitleCache.url(forVideo: video.path, source: "en-US", target: nil)
        try FileManager.default.createDirectory(at: srt.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc = SRT.document([SubtitleCue(start: 0, end: 30, text: "Hello.")])
        try doc.write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(video)
        #expect(await waitUntil { w.clipSubtitleFile != nil })
        let out = video.deletingLastPathComponent().appendingPathComponent("e.srt")
        try "old".write(to: out, atomically: true, encoding: .utf8)
        try w.exportAISubtitles(to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == doc)
        try w.exportAISubtitles(to: srt)                              // the cached file itself
        #expect(try String(contentsOf: srt, encoding: .utf8) == doc)
    }

    @Test("PA5 closing the player cancels a running clip export")
    func shutdownCancelsExport() async throws {
        let video = try copy("long.mp4")
        let out = video.deletingLastPathComponent().appendingPathComponent("clip.mp4")
        let w = PlayerWindowController()
        w.revealExported = { _ in Issue.record("not after closing") }
        w.open(video)
        #expect(await waitUntil { w.loadedPath == video.path })
        w.runClipExport(source: video, range: ClipRange(start: 0, end: 19.9), format: .video, subtitles: nil, to: out)
        try await Task.sleep(for: .milliseconds(300))
        w.shutdown()
        #expect(await waitUntil(5) { !w.isExportingClip })
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}

@Suite(.serialized) @MainActor struct EngineSubtitleReloadTests {
    @Test("EN1 adding a subtitle file again after it was rewritten shows the new text")
    func readdReloads() async throws {
        let engine = try MPVEngine(extraOptions: [("vo", "null")])      // no window: decode only
        defer { engine.shutdown() }
        engine.load(sample)
        engine.setPaused(true)
        #expect(await waitUntil { engine.state.duration > 0 })
        engine.seek(to: 2)
        let srt = TestTemp.directory.appendingPathComponent("re-\(UUID().uuidString).srt")
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "First")]).write(to: srt, atomically: true, encoding: .utf8)
        engine.addSubtitle(path: srt.path, title: "AI")
        #expect(await waitUntil { engine.property("sub-text") == "First" })
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "Second")]).write(to: srt, atomically: true, encoding: .utf8)
        engine.addSubtitle(path: srt.path, title: "AI")
        #expect(await waitUntil { engine.property("sub-text") == "Second" }, "now: \(engine.property("sub-text") ?? "nil")")
        #expect(engine.trackCounts().subtitle == 1)
    }
}
