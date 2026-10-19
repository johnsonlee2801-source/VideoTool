import AppKit
import Testing
@testable import VideoTool

// Subtitles while they are being made (user, 2026-10-19): the first lines show in
// seconds, the rest follow in the background, and the card shows how far it got.

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

/// Streams `head` segments at once, waits for the test, then streams the rest.
final class StreamingFake: StreamingSpeechRecognizing, @unchecked Sendable {
    let segments: [SpeechSegment]
    let head: Int
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var waiting = false
    init(count: Int, head: Int, spacing: Double = 0.4) {
        segments = (0..<count).map { SpeechSegment(text: "Line \($0).", start: Double($0) * spacing, end: Double($0) * spacing + 0.3, words: []) }
        self.head = head
    }
    func open() {
        lock.lock(); opened = true; let g = gate; gate = nil; lock.unlock()
        g?.resume()
    }
    func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
        try await transcribe(audio: audio, locale: locale, duration: duration, progress: progress, onSegment: { _ in })
    }
    func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void,
                    onSegment: @escaping @Sendable (SpeechSegment) -> Void) async throws -> [SpeechSegment] {
        for s in segments.prefix(head) { onSegment(s) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock(); waiting = true
            if opened { lock.unlock(); c.resume() } else { gate = c; lock.unlock() }
        }
        try Task.checkCancellation()
        for s in segments.dropFirst(head) { onSegment(s) }
        return segments
    }
}

final class BatchTranslator: SubtitleTranslating, @unchecked Sendable {
    var calls = 0
    var failFromCall: Int?
    func translate(_ lines: [String], from: String, to: String) async throws -> [String] {
        calls += 1
        if let f = failFromCall, calls >= f { throw AISubtitleError.translationUnavailable }
        return lines.map { "译" + $0 }
    }
}

private final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _counts: [Int] = []
    private var _last: [SubtitleCue] = []
    func add(_ cues: [SubtitleCue]) { lock.lock(); _counts.append(cues.count); _last = cues; lock.unlock() }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return _counts }
    var last: [SubtitleCue] { lock.lock(); defer { lock.unlock() }; return _last }
}

private func pipeline(_ rec: SpeechRecognizing, _ tr: SubtitleTranslating?, dir: URL) -> AISubtitlePipeline {
    AISubtitlePipeline(recognizer: rec, translator: tr, cacheDirectory: dir, extract: { _, wav, _, _ in
        try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: 100).write(to: wav); return .success(20)
    })
}
private func newDir() -> URL { TestTemp.directory.appendingPathComponent("lv-\(UUID().uuidString)") }

struct LiveSubtitlePipelineTests {
    @Test("LV1 the first lines arrive, translated, while recognition is still going; the rest follow")
    func firstLinesEarly() async throws {
        let rec = StreamingFake(count: 40, head: 3), tr = BatchTranslator(), log = PartialLog()
        let p = pipeline(rec, tr, dir: newDir())
        let job = Task { try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "zh-Hans"), progress: { _, _ in },
                                         partial: { log.add($0) }) }
        let deadline = Date().addingTimeInterval(5)
        while log.counts.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rec.waiting, "recognition is still running")
        #expect((log.counts.first ?? 0) >= 2)
        #expect(log.last.allSatisfy { $0.translation?.hasPrefix("译") == true })
        rec.open()
        let out = try await job.value
        #expect(out.cueCount == 40 && !out.translationSkipped)
        #expect(log.counts == log.counts.sorted(), "lines are only ever added")
        #expect(log.counts.last == 40)
        #expect(log.counts.count >= 2)
        let final = SRT.parse(try String(contentsOf: out.srt, encoding: .utf8))
        #expect(final.count == 40)
    }

    @Test("LV2 a recogniser that cannot stream still gives subtitles (shown once, at the end)") func nonStreaming() async throws {
        final class Plain: SpeechRecognizing, @unchecked Sendable {
            func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
                [SpeechSegment(text: "Hello.", start: 0, end: 1, words: []), SpeechSegment(text: "Bye.", start: 2, end: 3, words: [])]
            }
        }
        let log = PartialLog()
        let out = try await pipeline(Plain(), nil, dir: newDir()).run(.init(video: "/v/a.mkv", source: "en-US", target: nil),
                                                                      progress: { _, _ in }, partial: { log.add($0) })
        #expect(out.cueCount == 2 && log.counts.last == 2)
    }

    @Test("LV3 reusing an earlier recognition: translation also shows up batch by batch") func reuseProgressive() async throws {
        let dir = newDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cues = (0..<90).map { SubtitleCue(start: Double($0), end: Double($0) + 0.8, text: "L\($0)") }
        try SRT.document(cues).write(to: SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: nil, in: dir),
                                     atomically: true, encoding: .utf8)
        let log = PartialLog()
        let out = try await pipeline(StreamingFake(count: 1, head: 1), BatchTranslator(), dir: dir)
            .run(.init(video: "/v/a.mkv", source: "en-US", target: "zh-Hans"), progress: { _, _ in }, partial: { log.add($0) })
        #expect(out.cueCount == 90)
        #expect(log.counts.count >= 3 && log.counts.last == 90)
    }

    @Test("LV4 translation failing part-way leaves a consistent original-only file and says so") func translationStops() async throws {
        let rec = StreamingFake(count: 60, head: 3), tr = BatchTranslator(); tr.failFromCall = 2
        rec.open()
        let dir = newDir()
        let out = try await pipeline(rec, tr, dir: dir).run(.init(video: "/v/a.mkv", source: "en-US", target: "ja"),
                                                            progress: { _, _ in }, partial: { _ in })
        #expect(out.translationSkipped && out.cueCount == 60)
        #expect(out.srt == SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: nil, in: dir))
        #expect(!(try String(contentsOf: out.srt, encoding: .utf8)).contains("译"))
    }

    @Test("LV5 cancelling while lines stream in stops the job and writes no finished file") func cancelLive() async throws {
        let rec = StreamingFake(count: 40, head: 3), log = PartialLog(), dir = newDir()
        let p = pipeline(rec, BatchTranslator(), dir: dir)
        let job = Task { try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "zh-Hans"), progress: { _, _ in },
                                         partial: { log.add($0) }) }
        let deadline = Date().addingTimeInterval(5)
        while log.counts.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        p.cancel(); job.cancel(); rec.open()
        await #expect(throws: AISubtitleError.cancelled) { try await job.value }
        #expect(!FileManager.default.fileExists(atPath: SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: "zh-Hans", in: dir).path))
    }
}

@Suite(.serialized) @MainActor struct LiveSubtitlePlayerTests {
    @Test("LV6 a subtitle file rewritten on disk shows its new lines after a reload; it can also be removed")
    func reloadAndRemove() async throws {
        let srt = TestTemp.directory.appendingPathComponent("lv6-\(UUID().uuidString).srt")
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "first")]).write(to: srt, atomically: true, encoding: .utf8)
        let engine = try MPVEngine()
        let layer = MPVRenderLayer(engine: engine)
        defer { layer.teardown(); engine.shutdown() }
        var loaded = false
        engine.onEvent = { if case .fileLoaded = $0 { loaded = true } }
        engine.loadTarget(sample.path)
        #expect(await waitUntil { loaded })
        engine.addSubtitle(path: srt.path, title: "AI")
        engine.seek(to: 1)
        #expect(await waitUntil { engine.property("sub-text") == "first" })
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "second")]).write(to: srt, atomically: true, encoding: .utf8)
        engine.reloadSubtitle(path: srt.path)
        engine.seek(to: 1.5)
        #expect(await waitUntil { engine.property("sub-text") == "second" }, "shown: \(engine.property("sub-text") ?? "nil")")
        #expect(engine.trackCounts().subtitle == 1)
        engine.removeSubtitle(path: srt.path)
        #expect(await waitUntil { engine.trackCounts().subtitle == 0 })
    }

    @Test("LV7 the player shows subtitles while they are being made, then swaps in the finished file")
    func liveThenFinal() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.state.duration > 0 })
        let rec = StreamingFake(count: 30, head: 3), dir = newDir()
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: pipeline(rec, nil, dir: dir))
        #expect(await waitUntil { engine.trackCounts().subtitle == 1 }, "no live subtitles while the job runs")
        #expect(w.isMakingAISubtitles)
        #expect(w.aiCard.message.contains("已到"), "card: \(w.aiCard.message)")
        rec.open()
        #expect(await waitUntil { !w.isMakingAISubtitles })
        // Removing the live track and adding the finished one are two async player commands.
        let final = SubtitleCache.url(forVideo: sample.path, source: "en-US", target: nil, in: dir)
            .deletingPathExtension().appendingPathExtension("ass")          // shown through its .ass
        #expect(await waitUntil { engine.trackCounts().subtitle == 1 && engine.property("current-tracks/sub/external-filename") == final.path },
                "tracks \(engine.trackCounts().subtitle), current \(engine.property("current-tracks/sub/external-filename") ?? "nil")")
        #expect(w.aiCard.message.contains("字幕已生成"))
    }

    @Test("LV8 cancelling removes the live subtitles and their temporary file") func cancelRemovesLive() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.state.duration > 0 })
        let rec = StreamingFake(count: 30, head: 3), dir = newDir()
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: pipeline(rec, nil, dir: dir))
        #expect(await waitUntil { engine.trackCounts().subtitle == 1 })
        let live = try #require(engine.property("current-tracks/sub/external-filename"))
        w.cancelAISubtitles(showing: "已取消生成字幕")
        rec.open()
        #expect(await waitUntil { engine.trackCounts().subtitle == 0 })
        #expect(!FileManager.default.fileExists(atPath: live))
    }
}
