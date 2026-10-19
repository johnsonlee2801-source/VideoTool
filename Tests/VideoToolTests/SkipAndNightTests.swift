import AppKit
import Testing
@testable import VideoTool

// Skip intros/outros per series, and night mode (2026-10-19).

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

struct SkipRuleTests {
    @Test("SK1 one setting per series (and season); files without episode numbers share their folder's")
    func keys() {
        #expect(SkipStore.key(for: "/tv/Show.S01E02.mkv") == SkipStore.key(for: "/other/show s01e07.mp4"))
        #expect(SkipStore.key(for: "/tv/Show.S01E02.mkv") != SkipStore.key(for: "/tv/Show.S02E02.mkv"))
        #expect(SkipStore.key(for: "/a/lecture.mp4") == SkipStore.key(for: "/a/other.mov"))
        #expect(SkipStore.key(for: "/a/lecture.mp4") != SkipStore.key(for: "/b/lecture.mp4"))
    }

    @Test("SK2 the next episode is the next number of the same show and season in the folder") func next() throws {
        let dir = TestTemp.directory.appendingPathComponent("sk2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["Show S01E01.mp4", "Show S01E02.mkv", "Show S01E10.mp4", "Show S02E03.mp4", "Other S01E02.mp4", "notes.txt"] {
            try Data().write(to: dir.appendingPathComponent(n))
        }
        func next(_ n: String) -> String? { SeriesNavigator.nextEpisode(after: dir.appendingPathComponent(n).path).map { ($0 as NSString).lastPathComponent } }
        #expect(next("Show S01E01.mp4") == "Show S01E02.mkv")
        #expect(next("Show S01E02.mkv") == "Show S01E10.mp4", "gaps in numbering are fine")
        #expect(next("Show S01E10.mp4") == nil, "no season jump")
        #expect(next("Other S01E02.mp4") == nil)
    }

    @Test("SK3 settings persist and can be cleared") func store() throws {
        let suite = "videotool-tests-sk3-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = SkipStore(defaults: d)
        s.update("k") { $0.introEnd = 90 }
        s.update("k") { $0.outroStart = 1300 }
        #expect(SkipStore(defaults: d).skips(for: "k") == .init(introEnd: 90, outroStart: 1300))
        s.clear("k")
        #expect(SkipStore(defaults: d).skips(for: "k") == nil)
    }
}

@Suite(.serialized) @MainActor struct SkipPlayerTests {
    @Test("SK4 set the intro end and outro start once; episodes then skip both, going on to the next episode")
    func skipsInPlayer() async throws {
        let dir = TestTemp.directory.appendingPathComponent("sk4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e1 = dir.appendingPathComponent("Show S01E01.mp4"), e2 = dir.appendingPathComponent("Show S01E02.mp4")
        try FileManager.default.copyItem(at: sample, to: e1)
        try FileManager.default.copyItem(at: sample, to: e2)
        SkipStore().clear(SkipStore.key(for: e1.path))
        defer { SkipStore().clear(SkipStore.key(for: e1.path)) }
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(e1)
        let engine = try #require(w.engine)
        #expect(await waitUntil { w.loadedPath == e1.path })
        engine.setPaused(true)
        engine.seek(to: 3)
        #expect(await waitUntil { abs(engine.state.timePos - 3) < 0.2 })
        w.markIntroEnd(nil)
        #expect(w.playerView?.hud.text.contains("0:03") == true)
        engine.seek(to: 15)
        #expect(await waitUntil { abs(engine.state.timePos - 15) < 0.2 })
        w.markOutroStart(nil)

        engine.seek(to: 0)                                      // so reopening starts over, not resumes
        #expect(await waitUntil { engine.state.timePos < 0.2 })
        w.open(e1)
        #expect(await waitUntil { w.loadedPath == e1.path })
        #expect(await waitUntil { engine.state.timePos >= 2.9 }, "intro skipped: at \(engine.state.timePos)")
        #expect(await waitUntil { w.playerView?.hud.text == L("已跳过片头") }, "HUD: \(w.playerView?.hud.text ?? "")")
        engine.seek(to: 14)
        engine.setPaused(false)
        #expect(await waitUntil(8) { w.loadedPath == e2.path }, "outro skipped to the next episode")
        #expect(await waitUntil { engine.state.timePos >= 2.9 }, "the next episode skips its intro too")
    }
}

/// 16 kHz mono WAV: 3 s of a quiet 1 kHz tone (the voice band), then 3 s of a loud
/// 60 Hz rumble (explosions, a music bass line).
private func quietThenLoud() throws -> URL {
    let url = TestTemp.directory.appendingPathComponent("ql-\(UUID().uuidString).wav")
    let n = 16000 * 3
    var data = Data(count: n * 4)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for i in 0..<(2 * n) {
            let t = Double(i) / 16000
            p[i] = Int16(i < n ? 1200 * sin(2 * .pi * 1000 * t) : 22000 * sin(2 * .pi * 60 * t))
        }
    }
    try AudioExtractor.writeWAV(pcm: data, to: url)
    return url
}

@Suite(.serialized) @MainActor struct NightModeTests {
    /// RMS of the first and second half of what the player outputs for the clip.
    private func levels(night: Bool) async throws -> (quiet: Double, loud: Double) {
        let src = try quietThenLoud()
        let out = TestTemp.directory.appendingPathComponent("night-\(night)-\(UUID().uuidString).wav")
        let engine = try MPVEngine(extraOptions: [("vo", "null"), ("ao", "pcm"), ("ao-pcm-file", out.path), ("audio-samplerate", "16000"),
                                                  ("audio-channels", "mono"), ("audio-format", "s16"), ("untimed", "yes"), ("keep-open", "no")])
        engine.setNightMode(night)
        var ended = false
        engine.onEvent = { if case .endFile = $0 { ended = true } }
        engine.load(src)
        engine.setPaused(false)
        _ = await waitUntil(15) { ended }
        engine.shutdown()
        let samples = try Data(contentsOf: out).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        func rms(_ s: ArraySlice<Int16>) -> Double { sqrt(s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(s.count, 1))) }
        let half = samples.count / 2
        return (rms(samples[Int(Double(half) * 0.3)..<half]), rms(samples[(half + half / 3)...]))
    }

    @Test("NM1 night mode brings voice and rumble closer together (voice up, rumble down)") func narrower() async throws {
        let off = try await levels(night: false), on = try await levels(night: true)
        let ratioOff = off.loud / off.quiet, ratioOn = on.loud / on.quiet
        #expect(ratioOff > 10, "the clip itself: \(ratioOff)")
        #expect(ratioOn < ratioOff * 0.5, "night mode: loud/quiet \(ratioOn) vs \(ratioOff) without")
        #expect(on.quiet > off.quiet, "the voice band gets louder")
    }

    @Test("NM2 night mode is remembered and offered in the Play menu with a tick") func setting() throws {
        let w = PlayerWindowController()
        defer { w.shutdown(); NightMode.isOn = false }
        NightMode.isOn = false
        let item = NSMenuItem(title: "", action: #selector(PlayerWindowController.toggleNightMode(_:)), keyEquivalent: "")
        _ = w.validateMenuItem(item); #expect(item.state == .off)
        w.toggleNightMode(nil)
        #expect(NightMode.isOn)
        _ = w.validateMenuItem(item); #expect(item.state == .on)
        #expect(w.engine?.property("af")?.contains("night") == true)
    }
}
