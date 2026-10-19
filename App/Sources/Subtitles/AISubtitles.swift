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
        case .cannotOpen: return "无法读取这个视频的声音。"
        case .noAudio: return "这个视频没有声音，无法生成字幕。"
        case .noSpeech: return "没有识别到说话的声音，可能选错了视频语言。"
        case .unsupportedLanguage: return "这台 Mac 暂不支持识别这种语言。"
        case .translationUnavailable: return "这台 Mac 暂不支持这组语言的翻译，已生成原文字幕。"
        case .cancelled: return "已取消。"
        case .failed(let why): return "生成字幕失败：\(why)"
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
        .init(id: "en-US", name: "英语"), .init(id: "ja-JP", name: "日语"), .init(id: "zh-CN", name: "中文（普通话）"),
        .init(id: "yue-CN", name: "粤语"), .init(id: "ko-KR", name: "韩语"), .init(id: "fr-FR", name: "法语"),
        .init(id: "de-DE", name: "德语"), .init(id: "es-ES", name: "西班牙语"), .init(id: "it-IT", name: "意大利语"),
        .init(id: "pt-BR", name: "葡萄牙语"),
    ]

    static let targets: [Choice] = [
        .init(id: "zh-Hans", name: "简体中文"), .init(id: "zh-Hant", name: "繁體中文"), .init(id: "en", name: "英语"),
        .init(id: "ja", name: "日语"), .init(id: "ko", name: "韩语"),
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
    private let cacheDirectory: URL
    private let token = CancellationToken()

    init(recognizer: SpeechRecognizing, translator: SubtitleTranslating?,
         cacheDirectory: URL = SubtitleCache.directory,
         extract: @escaping Extract = { AudioExtractor.extract(source: $0, to: $1, isCancelled: $2, progress: $3) }) {
        self.recognizer = recognizer
        self.translator = translator
        self.cacheDirectory = cacheDirectory
        self.extract = extract
    }

    func cancel() { token.cancel() }
    var isCancelled: Bool { token.isCancelled }

    /// `progress(phase, fraction of that phase)`; may be called from any thread.
    func run(_ request: Request, progress: @escaping @Sendable (Phase, Double) -> Void) async throws -> Output {
        let wantsTranslation = request.target.map { !SubtitleLanguages.sameLanguage(request.source, $0) } ?? false
        let target = wantsTranslation ? request.target : nil
        let cached = SubtitleCache.url(forVideo: request.video, source: request.source, target: target, in: cacheDirectory)
        if FileManager.default.fileExists(atPath: cached.path) {
            progress(.done, 1)
            let cues = (try? String(contentsOf: cached, encoding: .utf8))?.components(separatedBy: " --> ").count ?? 1
            return Output(srt: cached, cueCount: max(cues - 1, 0), fromCache: true, translationSkipped: false)
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

        // 2. speech → cues
        progress(.recognizing, 0)
        let segments: [SpeechSegment]
        do {
            segments = try await recognizer.transcribe(audio: wav, locale: request.source, duration: duration,
                                                       progress: { progress(.recognizing, $0) })
        } catch {
            try checkCancelled(after: error)
            throw error
        }
        try checkCancelled()
        var cues = CueShaper.cues(from: segments)
        guard !cues.isEmpty else { throw AISubtitleError.noSpeech }

        // 3. translation (an unavailable language pair still leaves the original subtitles)
        var translationSkipped = false
        if let target {
            progress(.translating, 0)
            do {
                guard let translator else { throw AISubtitleError.translationUnavailable }
                let lines = try await translator.translate(cues.map(\.text), from: request.source, to: target)
                for i in cues.indices where i < lines.count { cues[i].translation = lines[i] }
            } catch AISubtitleError.cancelled {
                throw AISubtitleError.cancelled
            } catch {
                translationSkipped = true
            }
            try checkCancelled()
            progress(.translating, 1)
        }

        // 4. file
        let final = translationSkipped
            ? SubtitleCache.url(forVideo: request.video, source: request.source, target: nil, in: cacheDirectory)
            : cached
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try SRT.document(cues).write(to: final, atomically: true, encoding: .utf8)
        progress(.done, 1)
        return Output(srt: final, cueCount: cues.count, fromCache: false, translationSkipped: translationSkipped)
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
