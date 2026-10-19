import AppKit
import Testing
@testable import VideoTool

private final class Marker {}
private let sample = URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: "testsrc-20s", ofType: "mp4")!)

@MainActor
private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

struct SubtitleSizeFormatTests {
    private let cue = [SubtitleCue(start: 0, end: 1, text: "Hello", translation: "你好")]

    @Test("SZ1 sizes scale the text and the band together") func scaled() {
        let medium = ASS.document(cue, band: true, scale: 1), large = ASS.document(cue, band: true, scale: 1.25)
        #expect(medium.contains("\\fs64") && large.contains("\\fs80"))
        #expect(large.contains("l 1920 \(Int((Double(ASS.bandHeight(lines: 2)) * 1.25).rounded()))"))
        let small = ASS.document(cue, band: false, scale: 0.8)
        #expect(small.contains("\\fs51") && small.contains("\\fs42"))
    }

    @Test("SZ2 the chosen size is remembered (medium by default)") func remembered() throws {
        let suite = "videotool-tests-sz2-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(AISubtitlePreferences(defaults: d).scale == 1)
        AISubtitlePreferences(defaults: d).scale = 1.25
        #expect(AISubtitlePreferences(defaults: d).scale == 1.25)
        d.set(9.0, forKey: AISubtitlePreferences.scaleKey)
        #expect(AISubtitlePreferences(defaults: d).scale == 1, "unknown sizes fall back to medium")
    }
}

@Suite(.serialized) @MainActor struct SubtitleExportSizeWindowTests {
    private func withCachedSubtitles() async throws -> (PlayerWindowController, URL) {
        let prefs = AISubtitlePreferences()
        prefs.source = "en-US"; prefs.target = nil; prefs.scale = 1
        let srt = SubtitleCache.url(forVideo: sample.path, source: "en-US", target: nil)
        try FileManager.default.createDirectory(at: srt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "Hello there.")]).write(to: srt, atomically: true, encoding: .utf8)
        let w = PlayerWindowController()
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.trackCounts().subtitle == 1 })
        return (w, srt)
    }

    @Test("SZ3 export writes the AI subtitles as .srt; offered only when there are some") func export() async throws {
        let bare = PlayerWindowController()
        let item = NSMenuItem(title: "", action: #selector(PlayerWindowController.exportAISubtitles(_:)), keyEquivalent: "")
        #expect(!bare.validateMenuItem(item))
        bare.shutdown()
        let (w, srt) = try await withCachedSubtitles()
        defer { w.shutdown(); try? FileManager.default.removeItem(at: srt) }
        #expect(w.validateMenuItem(item))
        #expect(w.suggestedExportName == "testsrc-20s.srt")
        let target = TestTemp.directory.appendingPathComponent("export-\(UUID().uuidString).srt")
        try w.exportAISubtitles(to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == String(contentsOf: srt, encoding: .utf8))
    }

    @Test("SZ4 choosing a size redraws the subtitles on screen at once") func resize() async throws {
        let (w, srt) = try await withCachedSubtitles()
        defer { w.shutdown(); try? FileManager.default.removeItem(at: srt); AISubtitlePreferences().scale = 1 }
        let display = srt.deletingPathExtension().appendingPathExtension("ass")
        let item = NSMenuItem(title: "", action: #selector(PlayerWindowController.chooseSubtitleSize(_:)), keyEquivalent: "")
        item.representedObject = 1.25
        w.chooseSubtitleSize(item)
        #expect(AISubtitlePreferences().scale == 1.25)
        #expect(try String(contentsOf: display, encoding: .utf8).contains("Fontsize") )
        #expect(try String(contentsOf: display, encoding: .utf8).contains(",70,"), "medium 56 × 1.25 = 70")
        _ = w.validateMenuItem(item)
        #expect(item.state == .on)
    }
}
