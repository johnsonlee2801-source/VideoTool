import AppKit
import Testing
@testable import VideoTool

// Each video opens the way it was left (2026-10-19): audio track, subtitles on/off
// or which embedded track, and subtitle timing.

private final class Marker {}
private func fixture(_ n: String, _ e: String) -> URL { URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: n, ofType: e)!) }
private let multi = fixture("multi_audio_subs", "mkv")
private let other = fixture("testsrc-20s", "mp4")

@MainActor
private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

struct PlaybackMemoryStoreTests {
    @Test("PM1 settings are kept per file; the oldest go beyond the cap") func store() throws {
        let suite = "videotool-tests-pm1-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let m = PlaybackMemory(defaults: d, maxEntries: 2)
        m.update("/v/a.mkv") { $0.audioTrack = "2"; $0.subtitleDelay = 0.3 }
        m.update("/v/a.mkv") { $0.subtitleTrack = "no" }
        #expect(PlaybackMemory(defaults: d).entry(for: "/v/a.mkv") == .init(audioTrack: "2", subtitleTrack: "no", subtitleDelay: 0.3))
        m.update("/v/b.mkv") { $0.audioTrack = "1" }
        m.update("/v/c.mkv") { $0.audioTrack = "1" }
        #expect(m.entry(for: "/v/a.mkv") == nil && m.entry(for: "/v/c.mkv") != nil)
    }

    @Test("PM2 Z / X move subtitles 0.1 s earlier / later") func keys() {
        #expect(KeyCommandMap.command(for: KeyInput(key: "z")) == .subtitleDelay(-0.1))
        #expect(KeyCommandMap.command(for: KeyInput(key: "x")) == .subtitleDelay(0.1))
    }
}

@Suite(.serialized) @MainActor struct PlaybackMemoryPlayerTests {
    private func open(_ w: PlayerWindowController, _ url: URL) async throws -> MPVEngine {
        w.open(url)
        let engine = try #require(w.engine)
        // Wait until the window has handled the load (it restores the saved settings then).
        #expect(await waitUntil { engine.state.path == url.path && engine.state.duration > 0 && w.loadedPath == url.path })
        return engine
    }

    @Test("PM3 the audio track and the subtitle choice (a track, or off) come back when the video is reopened")
    func tracks() async throws {
        PlaybackMemory().forget(multi.path)
        let w = PlayerWindowController()
        defer { w.shutdown(); PlaybackMemory().forget(multi.path) }
        var engine = try await open(w, multi)
        #expect(engine.property("aid") == "1")
        w.cycleAudio(nil)
        #expect(await waitUntil { engine.property("aid") == "2" })
        let before = engine.property("sid")
        w.cycleSubtitle(nil)
        #expect(await waitUntil { engine.property("sid") != before })
        let chosen = try #require(engine.property("sid"))
        #expect(await waitUntil(10) { PlaybackMemory().entry(for: multi.path)?.subtitleTrack == chosen })
        engine = try await open(w, other)
        engine = try await open(w, multi)
        #expect(await waitUntil { engine.property("aid") == "2" }, "audio track back")
        #expect(await waitUntil { engine.property("sid") == chosen }, "subtitle choice back: \(chosen)")
        // and the other way round (on → off, or off → on)
        w.cycleSubtitle(nil)
        #expect(await waitUntil { engine.property("sid") != chosen })
        let second = try #require(engine.property("sid"))
        #expect(await waitUntil(10) { PlaybackMemory().entry(for: multi.path)?.subtitleTrack == second })
        engine = try await open(w, other)
        engine = try await open(w, multi)
        #expect(await waitUntil { engine.property("sid") == second })
    }

    @Test("PM4 subtitle timing: X three times is +0.3 s, shown on screen, and comes back next time")
    func delay() async throws {
        PlaybackMemory().forget(multi.path)
        let w = PlayerWindowController()
        defer { w.shutdown(); PlaybackMemory().forget(multi.path) }
        var engine = try await open(w, multi)
        for _ in 0..<3 { w.perform(.subtitleDelay(0.1)) }
        #expect(await waitUntil { abs((Double(engine.property("sub-delay") ?? "") ?? 0) - 0.3) < 0.001 })
        #expect(w.playerView?.hud.text.contains("+0.3") == true, "HUD: \(w.playerView?.hud.text ?? "")")
        engine = try await open(w, other)
        #expect(await waitUntil { abs((Double(engine.property("sub-delay") ?? "") ?? 1) - 0) < 0.001 }, "another video starts at 0")
        engine = try await open(w, multi)
        #expect(await waitUntil { abs((Double(engine.property("sub-delay") ?? "") ?? 0) - 0.3) < 0.001 })
    }
}
