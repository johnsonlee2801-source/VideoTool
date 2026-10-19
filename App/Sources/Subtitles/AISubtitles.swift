import CryptoKit
import Foundation

// AI subtitles (decision 2026-10-19: free for everyone, entirely on this Mac).
// Pipeline: soundtrack → WAV (mpv) → speech recognition (Apple, on-device)
// → readable cues → optional translation (Apple, on-device) → bilingual .srt,
// cached per file + languages and loaded into the player.

/// Recognises speech in a WAV file. The real one needs macOS 26 (`AppleSpeechRecognizer`).
protocol SpeechRecognizing {
    /// `progress` gets 0...1 of the audio covered so far.
    func transcribe(audio: URL, locale: String, duration: Double,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment]
}

/// A recogniser that can hand over each sentence as soon as it is recognised, so
/// subtitles can be shown while the rest of the video is still being processed.
protocol StreamingSpeechRecognizing: SpeechRecognizing {
    func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void,
                    onSegment: @escaping @Sendable (SpeechSegment) -> Void) async throws -> [SpeechSegment]
}

/// Translates lines, keeping their order. The real one needs macOS 26 (`AppleTranslator`).
protocol SubtitleTranslating {
    func translate(_ lines: [String], from source: String, to target: String) async throws -> [String]
}

enum AISubtitleError: Error, Equatable {
    case cannotOpen
    case noAudio
    case noSpeech
    case unsupportedLanguage
    case translationUnavailable
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .cannotOpen: return L("无法读取这个视频的声音。")
        case .noAudio: return L("这个视频没有声音，无法生成字幕。")
        case .noSpeech: return L("没有识别到说话的声音，可能选错了视频语言。")
        case .unsupportedLanguage: return L("这台 Mac 暂不支持识别这种语言。")
        case .translationUnavailable: return L("这台 Mac 暂不支持这组语言的翻译，已生成原文字幕。")
        case .cancelled: return L("已取消。")
        case .failed(let why): return L("生成字幕失败：%@", String(describing: why))
        }
    }
}

/// The languages offered in the dialog (filtered by what the Mac supports at run time).
enum SubtitleLanguages {
    struct Choice: Equatable {
        var id: String
        var name: String
    }

    static let sources: [Choice] = [
        .init(id: "en-US", name: L("英语")), .init(id: "ja-JP", name: L("日语")), .init(id: "zh-CN", name: L("中文（普通话）")),
        .init(id: "yue-CN", name: L("粤语")), .init(id: "ko-KR", name: L("韩语")), .init(id: "fr-FR", name: L("法语")),
        .init(id: "de-DE", name: L("德语")), .init(id: "es-ES", name: L("西班牙语")), .init(id: "it-IT", name: L("意大利语")),
        .init(id: "pt-BR", name: L("葡萄牙语")),
    ]

    static let targets: [Choice] = [
        .init(id: "zh-Hans", name: L("简体中文")), .init(id: "zh-Hant", name: L("繁體中文")), .init(id: "en", name: L("英语")),
        .init(id: "ja", name: L("日语")), .init(id: "ko", name: L("韩语")),
    ]

    /// "zh-CN" and "zh-Hans" are the same language; "yue" is not "zh".
    static func sameLanguage(_ source: String, _ target: String) -> Bool {
        func base(_ id: String) -> String { String(id.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "") }
        return base(source).lowercased() == base(target).lowercased()
    }
}

/// The languages chosen last time.
final class AISubtitlePreferences {
    static let sourceKey = "videotool.ai-subtitles.source"
    static let targetKey = "videotool.ai-subtitles.target"
    static let noTranslation = "none"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppData.defaults) { self.defaults = defaults }

    var source: String {
        get { defaults.string(forKey: Self.sourceKey) ?? "en-US" }
        set { defaults.set(newValue, forKey: Self.sourceKey) }
    }
    /// A target language id, or nil for "don't translate".
    var target: String? {
        get {
            let v = defaults.string(forKey: Self.targetKey) ?? "zh-Hans"
            return v == Self.noTranslation ? nil : v
        }
        set { defaults.set(newValue ?? Self.noTranslation, forKey: Self.targetKey) }
    }
}

/// Where generated subtitles are kept: one .srt per file version and language pair.
enum SubtitleCache {
    static var directory: URL { AppData.directory.appendingPathComponent("Subtitles", isDirectory: true) }

    static func url(forVideo path: String, source: String, target: String?, in dir: URL = directory) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(mtime)|\(source)|\(target ?? "-")"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(digest).srt")
    }
}

/// Runs the whole job for one video. Reports progress per phase; cancellable.
final class AISubtitlePipeline {
    enum Phase: Equatable { case extracting, recognizing, translating, done }

    struct Request: Equatable {
        var video: String
        var source: String
        var target: String?
    }

    struct Output: Equatable {
        var srt: URL
        var cueCount: Int
        var fromCache: Bool
        /// Translation was asked for but could not be done (original-only file).
        var translationSkipped: Bool
    }

    typealias Extract = (_ source: String, _ wav: URL, _ isCancelled: @escaping () -> Bool,
                         _ progress: @escaping (Double) -> Void) -> Result<Double, AudioExtractor.Failure>

    private let recognizer: SpeechRecognizing
    private let translator: SubtitleTranslating?
    private let extract: Extract
    let cacheDirectory: URL
    private let token = CancellationToken()

    init(recognizer: SpeechRecognizing, translator: SubtitleTranslating?,
         cacheDirectory: URL = SubtitleCache.directory,
         extract: @escaping Extract = { AudioExtractor.extract(source: $0, to: $1, isCancelled: $2, progress: $3) }) {
        self.recognizer = recognizer
        self.translator = translator
        self.cacheDirectory = cacheDirectory
        self.extract = extract
        liveFile = cacheDirectory.appendingPathComponent("live-\(UUID().uuidString).srt")
    }

    func cancel() { token.cancel() }
    var isCancelled: Bool { token.isCancelled }

    /// `progress(phase, fraction of that phase)`; may be called from any thread.
    /// Subtitles made so far, rewritten while the job runs (the player shows this file).
    let liveFile: URL

    /// Lines handed to `partial` at once at the start, then about every this many.
    static let firstBatch = 2, batch = 20
    static let batchSeconds = 3.0

    /// `progress(phase, fraction of that phase)`; `partial(all cues so far)` while
    /// lines arrive (first after ~2 lines, then every ~20 lines or 3 s), translated
    /// if a translation was asked for. Both may be called from any thread.
    func run(_ request: Request, progress: @escaping @Sendable (Phase, Double) -> Void,
             partial: (@Sendable ([SubtitleCue]) -> Void)? = nil) async throws -> Output {
        let wantsTranslation = request.target.map { !SubtitleLanguages.sameLanguage(request.source, $0) } ?? false
        let target = wantsTranslation ? request.target : nil
        let cached = SubtitleCache.url(forVideo: request.video, source: request.source, target: target, in: cacheDirectory)
        if FileManager.default.fileExists(atPath: cached.path) {
            progress(.done, 1)
            let cues = (try? String(contentsOf: cached, encoding: .utf8))?.components(separatedBy: " --> ").count ?? 1
            return Output(srt: cached, cueCount: max(cues - 1, 0), fromCache: true, translationSkipped: false)
        }
        let live = LiveCues(source: request.source, target: target, translator: translator)

        // An earlier run already recognised this video (say its translation failed, or
        // another language was chosen): reuse that and only translate, batch by batch.
        let originalOnly = SubtitleCache.url(forVideo: request.video, source: request.source, target: nil, in: cacheDirectory)
        if target != nil, let text = try? String(contentsOf: originalOnly, encoding: .utf8) {
            let earlier = SRT.parse(text)
            if !earlier.isEmpty {
                progress(.translating, 0)
                for start in stride(from: 0, to: earlier.count, by: Self.batch) {
                    try await live.add(Array(earlier[start..<min(start + Self.batch, earlier.count)]))
                    try checkCancelled()
                    partial?(live.cues)
                    progress(.translating, Double(live.cues.count) / Double(earlier.count))
                }
                return try finish(live, request: request, final: cached, progress: progress)
            }
        }

        // 1. soundtrack
        let wav = cacheDirectory.appendingPathComponent("audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        progress(.extracting, 0)
        let token = self.token
        let extracted = await Task.detached { [extract] in
            extract(request.video, wav, { token.isCancelled }, { progress(.extracting, $0) })
        }.value
        let duration: Double
        switch extracted {
        case .success(let d): duration = d
        case .failure(.cancelled): throw AISubtitleError.cancelled
        case .failure(.noAudio): throw AISubtitleError.noAudio
        case .failure(.cannotOpen): throw AISubtitleError.cannotOpen
        }
        try checkCancelled()

        // 2. speech → cues → (translation), handed over in batches while recognition runs
        progress(.recognizing, 0)
        let (stream, feed) = AsyncStream<SpeechSegment>.makeStream()
        let recognizer = self.recognizer
        let recognition = Task { () throws -> [SpeechSegment] in
            defer { feed.finish() }
            if let streaming = recognizer as? StreamingSpeechRecognizing {
                return try await streaming.transcribe(audio: wav, locale: request.source, duration: duration,
                                                      progress: { progress(.recognizing, $0) }, onSegment: { feed.yield($0) })
            }
            return try await recognizer.transcribe(audio: wav, locale: request.source, duration: duration,
                                                   progress: { progress(.recognizing, $0) })
        }
        var pending: [SpeechSegment] = []
        var streamed = 0
        var lastHandOver = Date()
        do {
            for await segment in stream {
                streamed += 1
                pending.append(segment)
                let due = live.cues.isEmpty ? pending.count >= Self.firstBatch
                    : pending.count >= Self.batch || Date().timeIntervalSince(lastHandOver) >= Self.batchSeconds
                guard due else { continue }
                try await live.add(CueShaper.cues(from: pending))
                pending = []
                lastHandOver = Date()
                try checkCancelled()
                partial?(live.cues)
            }
            let all = try await recognition.value
            if streamed == 0 { pending = all }                 // the recogniser could not stream
        } catch {
            recognition.cancel()
            try checkCancelled(after: error)
            throw error
        }
        try checkCancelled()
        if !pending.isEmpty {
            try await live.add(CueShaper.cues(from: pending))
            try checkCancelled()
            partial?(live.cues)
        }
        guard !live.cues.isEmpty else { throw AISubtitleError.noSpeech }
        // Kept in any case: a later translation (or retry) starts from here.
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try SRT.document(live.cues.map { var c = $0; c.translation = nil; return c })
            .write(to: originalOnly, atomically: true, encoding: .utf8)
        return try finish(live, request: request, final: cached, progress: progress)
    }

    /// The finished file: bilingual, or original-only if translation was not possible.
    private func finish(_ live: LiveCues, request: Request, final cached: URL,
                        progress: @escaping @Sendable (Phase, Double) -> Void) throws -> Output {
        let final = live.translationSkipped
            ? SubtitleCache.url(forVideo: request.video, source: request.source, target: nil, in: cacheDirectory)
            : cached
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try SRT.document(live.cues).write(to: final, atomically: true, encoding: .utf8)
        progress(.done, 1)
        return Output(srt: final, cueCount: live.cues.count, fromCache: false, translationSkipped: live.translationSkipped)
    }

    private func checkCancelled() throws {
        if token.isCancelled || Task.isCancelled { throw AISubtitleError.cancelled }
    }

    /// Whatever a step throws once the job was cancelled (CancellationError, a
    /// recogniser error…) is a cancellation, not a failure to report.
    private func checkCancelled(after error: Error) throws {
        if error is CancellationError { throw AISubtitleError.cancelled }
        try checkCancelled()
    }
}

/// The cues of a job so far. New lines keep time order after the earlier ones and
/// are translated as they come in. If translation fails part-way, every line goes
/// back to the original only, so the result is never half translated.
final class LiveCues {
    private(set) var cues: [SubtitleCue] = []
    private(set) var translationSkipped = false
    private let source: String
    private let target: String?
    private let translator: SubtitleTranslating?

    init(source: String, target: String?, translator: SubtitleTranslating?) {
        self.source = source
        self.target = target
        self.translator = translator
    }

    func add(_ new: [SubtitleCue]) async throws {
        var batch = new
        var previousEnd = cues.last?.end ?? -.infinity
        for i in batch.indices {
            if batch[i].start < previousEnd {
                batch[i].start = previousEnd
                batch[i].end = max(batch[i].end, previousEnd + CueShaper.minDuration)
            }
            previousEnd = batch[i].end
        }
        if let target, !translationSkipped, !batch.isEmpty {
            do {
                guard let translator else { throw AISubtitleError.translationUnavailable }
                let lines = try await translator.translate(batch.map(\.text), from: source, to: target)
                for i in batch.indices where i < lines.count { batch[i].translation = lines[i] }
            } catch AISubtitleError.cancelled {
                throw AISubtitleError.cancelled
            } catch {
                translationSkipped = true
                for i in cues.indices { cues[i].translation = nil }
            }
        }
        cues += batch
    }
}
