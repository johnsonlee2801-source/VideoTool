import Foundation
import Speech
import Testing
@testable import VideoTool

private final class Marker {}
private func fixture(_ name: String, _ ext: String) -> String { Bundle(for: Marker.self).path(forResource: name, ofType: ext)! }
private func tempDir() -> URL {
    TestTemp.directory.appendingPathComponent("aisub-\(UUID().uuidString)", isDirectory: true)
}

private final class FakeRecognizer: SpeechRecognizing, @unchecked Sendable {
    var segments = [SpeechSegment(text: "Hello, everyone.", start: 0, end: 1.2, words: []),
                    SpeechSegment(text: "Press and hold the picture.", start: 1.5, end: 3, words: [])]
    var calls: [(String, Double)] = []
    var error: Error?
    func transcribe(audio: URL, locale: String, duration: Double,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
        calls.append((locale, duration))
        #expect(FileManager.default.fileExists(atPath: audio.path), "the WAV exists while recognising")
        progress(0.5); progress(1)
        if let error { throw error }
        return segments
    }
}

private final class FakeTranslator: SubtitleTranslating, @unchecked Sendable {
    var calls: [(String, String)] = []
    var fail = false
    func translate(_ lines: [String], from source: String, to target: String) async throws -> [String] {
        calls.append((source, target))
        if fail { throw AISubtitleError.translationUnavailable }
        return lines.map { "译：" + $0 }
    }
}

private func fakeExtract(_ result: Result<Double, AudioExtractor.Failure>) -> AISubtitlePipeline.Extract {
    { _, wav, _, progress in
        if case .success = result {
            try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(count: 100).write(to: wav)
        }
        progress(1)
        return result
    }
}

struct AISubtitlePipelineTests {
    @Test("AI1 extract → recognise → translate → bilingual .srt; the WAV is cleaned up") func fullRun() async throws {
        let dir = tempDir(), rec = FakeRecognizer(), tr = FakeTranslator()
        let p = AISubtitlePipeline(recognizer: rec, translator: tr, cacheDirectory: dir, extract: fakeExtract(.success(3)))
        let out = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "zh-Hans"), progress: { _, _ in })
        #expect(out.cueCount == 2 && !out.fromCache && !out.translationSkipped)
        let srt = try String(contentsOf: out.srt, encoding: .utf8)
        #expect(srt.contains("译：Hello, everyone.\nHello, everyone."))
        #expect(rec.calls.first?.0 == "en-US" && rec.calls.first?.1 == 3)
        #expect(tr.calls.first?.0 == "en-US" && tr.calls.first?.1 == "zh-Hans")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }
        #expect(leftovers.isEmpty)
    }

    @Test("AI2 a second run for the same video and languages comes from the cache") func cached() async throws {
        let dir = tempDir(), rec = FakeRecognizer()
        let video = TestTemp.directory.appendingPathComponent("v-\(UUID().uuidString).mkv")
        try Data(count: 10).write(to: video)
        let p = AISubtitlePipeline(recognizer: rec, translator: FakeTranslator(), cacheDirectory: dir, extract: fakeExtract(.success(3)))
        let req = AISubtitlePipeline.Request(video: video.path, source: "en-US", target: "zh-Hans")
        _ = try await p.run(req, progress: { _, _ in })
        let second = try await p.run(req, progress: { _, _ in })
        #expect(second.fromCache && second.cueCount == 2)
        #expect(rec.calls.count == 1)
    }

    @Test("AI3 no translation when none is wanted or the target is the video's own language") func noTranslation() async throws {
        for target in [nil, "zh-Hans"] as [String?] {
            let tr = FakeTranslator()
            let p = AISubtitlePipeline(recognizer: FakeRecognizer(), translator: tr, cacheDirectory: tempDir(),
                                       extract: fakeExtract(.success(3)))
            let out = try await p.run(.init(video: "/v/a.mkv", source: "zh-CN", target: target), progress: { _, _ in })
            #expect(tr.calls.isEmpty)
            #expect(!(try String(contentsOf: out.srt, encoding: .utf8)).contains("译："))
        }
    }

    @Test("AI4 an unavailable translation still gives the original subtitles, and says so") func translationFails() async throws {
        let tr = FakeTranslator(); tr.fail = true
        let p = AISubtitlePipeline(recognizer: FakeRecognizer(), translator: tr, cacheDirectory: tempDir(),
                                   extract: fakeExtract(.success(3)))
        let out = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "ja"), progress: { _, _ in })
        #expect(out.translationSkipped && out.cueCount == 2)
    }

    @Test("AI5 no sound, no speech and cancellation are reported as such", arguments: [
        (Result<Double, AudioExtractor.Failure>.failure(.noAudio), AISubtitleError.noAudio),
        (.failure(.cannotOpen("x")), .cannotOpen),
        (.failure(.cancelled), .cancelled),
    ])
    func failures(extract: Result<Double, AudioExtractor.Failure>, expected: AISubtitleError) async {
        let p = AISubtitlePipeline(recognizer: FakeRecognizer(), translator: nil, cacheDirectory: tempDir(), extract: fakeExtract(extract))
        await #expect(throws: expected) { try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: nil), progress: { _, _ in }) }
    }

    @Test("AI6 silence (nothing recognised) is 'no speech'") func silence() async {
        let rec = FakeRecognizer(); rec.segments = []
        let p = AISubtitlePipeline(recognizer: rec, translator: nil, cacheDirectory: tempDir(), extract: fakeExtract(.success(3)))
        await #expect(throws: AISubtitleError.noSpeech) { try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: nil), progress: { _, _ in }) }
    }

    @Test("AI7 progress goes through the phases in order and ends at done") func phases() async throws {
        final class Log: @unchecked Sendable { var phases: [AISubtitlePipeline.Phase] = []; let lock = NSLock() }
        let log = Log()
        let p = AISubtitlePipeline(recognizer: FakeRecognizer(), translator: FakeTranslator(), cacheDirectory: tempDir(),
                                   extract: fakeExtract(.success(3)))
        _ = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "zh-Hans"), progress: { ph, _ in
            log.lock.lock(); if log.phases.last != ph { log.phases.append(ph) }; log.lock.unlock()
        })
        // Since 2026-10-19 translation runs batch by batch during recognition (live subtitles).
        #expect(log.phases == [.extracting, .recognizing, .done])
    }

    @Test("AI8 language helpers: same-language check, cache key changes with languages") func helpers() {
        #expect(SubtitleLanguages.sameLanguage("zh-CN", "zh-Hans"))
        #expect(SubtitleLanguages.sameLanguage("en-US", "en"))
        #expect(!SubtitleLanguages.sameLanguage("yue-CN", "zh-Hans"))
        let a = SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: "zh-Hans", in: URL(fileURLWithPath: "/c"))
        #expect(a != SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: nil, in: URL(fileURLWithPath: "/c")))
        #expect(a != SubtitleCache.url(forVideo: "/v/b.mkv", source: "en-US", target: "zh-Hans", in: URL(fileURLWithPath: "/c")))
        #expect(a == SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: "zh-Hans", in: URL(fileURLWithPath: "/c")))
    }

    @Test("AI9 chosen languages are remembered; 'don't translate' is kept as nil") func prefs() throws {
        let suite = "videotool-tests-ai-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let a = AISubtitlePreferences(defaults: d)
        #expect(a.source == "en-US" && a.target == "zh-Hans")
        a.source = "ja-JP"; a.target = nil
        let b = AISubtitlePreferences(defaults: d)
        #expect(b.source == "ja-JP" && b.target == nil)
    }
}

// Real engine and real recognition (the system downloads the English model on first use).
@Suite(.serialized) struct AISubtitleIntegrationTests {
    @Test("AI10 the soundtrack of an MKV becomes a 16 kHz mono WAV, much faster than real time")
    func extractsAudio() throws {
        let wav = tempDir().appendingPathComponent("a.wav")
        let t0 = Date()
        let result = AudioExtractor.extract(source: fixture("speech-en", "mkv"), to: wav)
        let seconds = try result.get()
        #expect(abs(seconds - 8.64) < 0.2, "the spoken track is 8.64 s; the black video runs a little longer")
        #expect(Date().timeIntervalSince(t0) < 5)
        let header = try Data(contentsOf: wav).prefix(44)
        #expect(header.prefix(4) == Data("RIFF".utf8))
        #expect(header[22] == 1, "mono")
        #expect(header[24...27].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 16000)
    }

    @Test("AI11 a video without sound and a missing file are reported, not crashed on") func extractFailures() {
        #expect(AudioExtractor.extract(source: fixture("testsrc-20s", "mp4"), to: tempDir().appendingPathComponent("b.wav"))
                == .failure(.noAudio))
        if case .failure(.cannotOpen) = AudioExtractor.extract(source: "/nope/missing.mkv", to: tempDir().appendingPathComponent("c.wav")) {
        } else { Issue.record("a missing file must fail to open") }
    }

    @Test("AI12 cancelling stops the extraction and leaves no file") func extractCancel() {
        let wav = tempDir().appendingPathComponent("d.wav")
        #expect(AudioExtractor.extract(source: fixture("speech-en", "mkv"), to: wav, isCancelled: { true }) == .failure(.cancelled))
        #expect(!FileManager.default.fileExists(atPath: wav.path))
    }

    @Test("AI13 end to end with Apple's recogniser: the spoken words come back, timed and in order")
    func recognisesSpeech() async throws {
        guard #available(macOS 26.0, *) else { return }        // the feature needs macOS 26
        try #require(SpeechTranscriber.isAvailable, "on macOS 26+ recognition must be available, not silently skipped")
        let p = AISubtitlePipeline(recognizer: AppleSpeechRecognizer(), translator: nil, cacheDirectory: tempDir())
        let out = try await p.run(.init(video: fixture("speech-en", "mkv"), source: "en-US", target: nil), progress: { _, _ in })
        let srt = try String(contentsOf: out.srt, encoding: .utf8).lowercased()
        #expect(srt.contains("hold the picture"))
        #expect(srt.contains("normal speed"))
        #expect(srt.hasPrefix("1\n00:00:0"))
        #expect(out.cueCount >= 3)
    }
}

struct SubtitleReuseTests {
    final class CountingRecognizer: SpeechRecognizing, @unchecked Sendable {
        var calls = 0
        func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
            calls += 1
            return [SpeechSegment(text: "Hello, everyone.", start: 0, end: 1.2, words: []),
                    SpeechSegment(text: "Press and hold the picture.", start: 1.5, end: 3.25, words: [])]
        }
    }
    final class SwitchableTranslator: SubtitleTranslating, @unchecked Sendable {
        var works = false
        func translate(_ lines: [String], from: String, to: String) async throws -> [String] {
            guard works else { throw AISubtitleError.translationUnavailable }
            return lines.map { "译：" + $0 }
        }
    }

    @Test("RT1 SRT files read back into the same cues (to reuse earlier recognition)") func parseRoundTrip() {
        let cues = [SubtitleCue(start: 0, end: 1.2, text: "Hello, everyone."), SubtitleCue(start: 3725.5, end: 3727, text: "二")]
        #expect(SRT.parse(SRT.document(cues)) == cues)
        #expect(SRT.parse("1\r\n00:00:01,000 --> 00:00:02,500\r\nWindows line ends\r\n\r\n") ==
                [SubtitleCue(start: 1, end: 2.5, text: "Windows line ends")])
        #expect(SRT.parse("garbage").isEmpty)
    }

    @Test("RT2 after a failed translation, trying again only translates: no second extraction or recognition")
    func retryTranslatesOnly() async throws {
        let dir = TestTemp.directory.appendingPathComponent("rt2-\(UUID().uuidString)")
        let rec = CountingRecognizer(), tr = SwitchableTranslator()
        var extractions = 0
        let p = AISubtitlePipeline(recognizer: rec, translator: tr, cacheDirectory: dir, extract: { _, wav, _, _ in
            extractions += 1
            try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(count: 100).write(to: wav); return .success(3)
        })
        let req = AISubtitlePipeline.Request(video: "/v/a.mkv", source: "en-US", target: "zh-Hans")
        let first = try await p.run(req, progress: { _, _ in })
        #expect(first.translationSkipped)
        tr.works = true
        let second = try await p.run(req, progress: { _, _ in })
        #expect(!second.translationSkipped && second.cueCount == 2)
        #expect(rec.calls == 1 && extractions == 1)
        #expect(try String(contentsOf: second.srt, encoding: .utf8).contains("译：Press and hold the picture.\nPress and hold the picture."))
    }

    @Test("RT3 a translated run also keeps the original-only file, so another target language reuses it")
    func otherTarget() async throws {
        let dir = TestTemp.directory.appendingPathComponent("rt3-\(UUID().uuidString)")
        let rec = CountingRecognizer(), tr = SwitchableTranslator(); tr.works = true
        let p = AISubtitlePipeline(recognizer: rec, translator: tr, cacheDirectory: dir, extract: { _, wav, _, _ in
            try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(count: 100).write(to: wav); return .success(3)
        })
        _ = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "zh-Hans"), progress: { _, _ in })
        #expect(FileManager.default.fileExists(atPath: SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: nil, in: dir).path))
        _ = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "ja"), progress: { _, _ in })
        #expect(rec.calls == 1)
    }
}
