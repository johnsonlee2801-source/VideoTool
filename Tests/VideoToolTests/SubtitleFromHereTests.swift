import AVFoundation
import Testing
@testable import VideoTool

// AI subtitles start where you are watching (2026-10-19): starting an hour into a
// film, the lines for that hour come first, then the beginning is filled in.

/// A 16 kHz mono 16-bit WAV of `seconds` (a quiet tone, so readers accept it).
private func wav(seconds: Double) throws -> URL {
    let url = TestTemp.directory.appendingPathComponent("from-\(UUID().uuidString).wav")
    let n = Int(seconds * 16000)
    var data = Data(count: n * 2)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for i in 0..<n { p[i] = Int16(800 * sin(Double(i) * 0.05)) }
    }
    try AudioExtractor.writeWAV(pcm: data, to: url)
    return url
}

/// Emits one sentence per 10 s of whatever audio it is given (times relative to that audio).
final class ClockRecognizer: StreamingSpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _lengths: [Double] = []
    var lengths: [Double] { lock.lock(); defer { lock.unlock() }; return _lengths }
    func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
        try await transcribe(audio: audio, locale: locale, duration: duration, progress: progress, onSegment: { _ in })
    }
    func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void,
                    onSegment: @escaping @Sendable (SpeechSegment) -> Void) async throws -> [SpeechSegment] {
        let file = try AVAudioFile(forReading: audio)
        let length = Double(file.length) / file.fileFormat.sampleRate
        lock.lock(); _lengths.append(length); lock.unlock()
        var out: [SpeechSegment] = []
        for t in stride(from: 0.0, to: length - 1, by: 10) {
            let s = SpeechSegment(text: "Line.", start: t + 1, end: t + 4, words: [])
            out.append(s); onSegment(s)
            progress(min((t + 10) / length, 1))
        }
        return out
    }
}

private final class Log: @unchecked Sendable {
    let lock = NSLock()
    var first: [SubtitleCue]?
    var progress: [Double] = []
}

struct SubtitleFromHereTests {
    @Test("FH1 a slice of a WAV is a valid WAV of the right length") func slice() throws {
        let src = try wav(seconds: 30)
        let out = TestTemp.directory.appendingPathComponent("slice-\(UUID().uuidString).wav")
        try AudioExtractor.slice(src, from: 10, to: 25, into: out)
        let file = try AVAudioFile(forReading: out)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 15) < 0.01)
    }

    @Test("FH2 starting at 1:00 of a 2:00 video: the lines from 1:00 on come first, then the start is filled in")
    func fromCurrentPosition() async throws {
        let audio = try wav(seconds: 120)
        let rec = ClockRecognizer(), log = Log()
        let p = AISubtitlePipeline(recognizer: rec, translator: nil,
                                   cacheDirectory: TestTemp.directory.appendingPathComponent("fh2-\(UUID().uuidString)"),
                                   extract: { _, _, out, _, _ in
                                       try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                                       try? FileManager.default.copyItem(at: audio, to: out)
                                       return .success(120) })
        let out = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: nil, startAt: 60),
                                  progress: { phase, f in if phase == .recognizing { log.lock.lock(); log.progress.append(f); log.lock.unlock() } },
                                  partial: { cues in log.lock.lock(); if log.first == nil { log.first = cues }; log.lock.unlock() })
        #expect(rec.lengths.map { $0.rounded() } == [60, 60], "two passes: from 1:00 to the end, then the start")
        let first = try #require(log.first)
        #expect(first.allSatisfy { $0.start >= 60 }, "first lines shown are where you are watching: \(first.map(\.start))")
        let final = SRT.parse(try String(contentsOf: out.srt, encoding: .utf8))
        #expect(final.count == 12)
        #expect(final.map(\.start) == final.map(\.start).sorted(), "in time order")
        #expect(final.contains { abs($0.start - 61) < 0.01 } && final.contains { abs($0.start - 1) < 0.01 }, "real times, not times within each half")
        #expect(log.progress == log.progress.sorted() && (log.progress.last ?? 0) > 0.95, "overall progress only rises: \(log.progress)")
    }

    @Test("FH3 near the start or the end there is no split (one pass from the beginning)") func noSplit() async throws {
        let audio = try wav(seconds: 120)
        for start in [0.0, 30, 100] {
            let rec = ClockRecognizer()
            let p = AISubtitlePipeline(recognizer: rec, translator: nil,
                                       cacheDirectory: TestTemp.directory.appendingPathComponent("fh3-\(UUID().uuidString)"),
                                       extract: { _, _, out, _, _ in
                                           try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                                           try? FileManager.default.copyItem(at: audio, to: out)
                                           return .success(120) })
            _ = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: nil, startAt: start), progress: { _, _ in })
            #expect(rec.lengths.count == 1, "start \(start)")
        }
    }

    @Test("FH4 lines arriving out of order are kept sorted without overlaps") func liveOrder() async throws {
        let live = LiveCues(source: "en-US", target: nil, translator: nil)
        try await live.add([SubtitleCue(start: 61, end: 64, text: "b"), SubtitleCue(start: 71, end: 74, text: "c")])
        try await live.add([SubtitleCue(start: 1, end: 4, text: "a"), SubtitleCue(start: 63, end: 65, text: "late overlap")])
        #expect(live.cues.map(\.text) == ["a", "b", "late overlap", "c"])
        for (x, y) in zip(live.cues, live.cues.dropFirst()) { #expect(x.end <= y.start + 1e-9) }
    }
}
