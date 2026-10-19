import AppKit
import AVFoundation
import Speech
import SwiftUI
import Translation

/// On-device speech recognition (macOS 26+). The language model is downloaded by
/// the system the first time a language is used; nothing leaves the Mac.
@available(macOS 26.0, *)
final class AppleSpeechRecognizer: SpeechRecognizing {
    func transcribe(audio: URL, locale id: String, duration: Double,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            throw AISubtitleError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> [SpeechSegment] in
            var out: [SpeechSegment] = []
            for try await r in transcriber.results {
                out.append(Self.segment(r))
                if duration > 0 { progress(min(r.range.end.seconds / duration, 1)) }
            }
            return out
        }
        do {
            let file = try AVAudioFile(forReading: audio)
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw AISubtitleError.failed(error.localizedDescription)
        }
        return try await collect.value
    }

    /// The dialog's languages that this Mac can recognise (all of them if the check fails).
    static func availableSources() async -> [SubtitleLanguages.Choice] {
        var out: [SubtitleLanguages.Choice] = []
        for s in SubtitleLanguages.sources where await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: s.id)) != nil {
            out.append(s)
        }
        return out.isEmpty ? SubtitleLanguages.sources : out
    }

    private static func segment(_ r: SpeechTranscriber.Result) -> SpeechSegment {
        var words: [SpeechWord] = []
        for run in r.text.runs {
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            words.append(SpeechWord(text: String(r.text[run.range].characters),
                                    start: range.start.seconds, end: range.end.seconds))
        }
        return SpeechSegment(text: String(r.text.characters), start: r.range.start.seconds,
                             end: r.range.end.seconds, words: words)
    }
}

/// On-device translation (macOS 26+). If the language pair is supported but its
/// pack is not installed yet, the system's own download prompt is shown in `window`.
@available(macOS 26.0, *)
final class AppleTranslator: SubtitleTranslating {
    private let window: () -> NSWindow?
    static let batchSize = 40

    init(window: @escaping () -> NSWindow?) { self.window = window }

    func translate(_ lines: [String], from source: String, to target: String) async throws -> [String] {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: from, to: to) {
        case .unsupported:
            throw AISubtitleError.translationUnavailable
        case .installed:
            return try await Self.run(TranslationSession(installedSource: from, target: to), lines)
        case .supported:
            return try await withPromptedSession(from: from, to: to) { try await Self.run($0, lines) }
        @unknown default:
            throw AISubtitleError.translationUnavailable
        }
    }

    private static func run(_ session: TranslationSession, _ lines: [String]) async throws -> [String] {
        var out = lines
        for range in batches(count: lines.count, size: batchSize) {
            if Task.isCancelled { throw AISubtitleError.cancelled }
            let requests = range.map { TranslationSession.Request(sourceText: lines[$0], clientIdentifier: String($0)) }
            let responses = try await session.translations(from: requests)
            out = merge(responses.map { ($0.clientIdentifier, $0.targetText) }, into: out)
        }
        return out
    }

    /// Consecutive index ranges of at most `size`.
    static func batches(count: Int, size: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: max(size, 1)).map { $0..<min($0 + max(size, 1), count) }
    }

    /// Puts each translation back at the line it came from (responses may arrive in
    /// any order); unknown or missing ids leave the original line in place.
    static func merge(_ responses: [(id: String?, text: String)], into lines: [String]) -> [String] {
        var out = lines
        for r in responses {
            if let i = r.id.flatMap(Int.init), out.indices.contains(i) { out[i] = r.text }
        }
        return out
    }

    /// A session from SwiftUI's `translationTask`, which lets the system ask the user
    /// to download the language pack. The session is only valid inside the closure.
    @MainActor
    private func withPromptedSession(from: Locale.Language, to: Locale.Language,
                                     _ work: @escaping (TranslationSession) async throws -> [String]) async throws -> [String] {
        guard let content = window()?.contentView else { throw AISubtitleError.translationUnavailable }
        let once = ResumeOnce<[String]>()
        var host: NSView?
        let cleanUp = { @MainActor in host?.removeFromSuperview(); host = nil }
        // Cancelling the job (or the user ignoring the download prompt and pressing
        // 取消) ends the wait; the continuation is resumed exactly once either way.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                let view = TranslationBridge(configuration: .init(source: from, target: to)) { session in
                    do {
                        try await session.prepareTranslation()
                        once.resume(.success(try await work(session)))
                    } catch {
                        once.resume(.failure(Task.isCancelled ? AISubtitleError.cancelled : AISubtitleError.translationUnavailable))
                    }
                    await cleanUp()
                }
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
                content.addSubview(hosting)
                host = hosting
            }
        } onCancel: {
            once.resume(.failure(AISubtitleError.cancelled))
            Task { await cleanUp() }
        }
    }
}

/// Resumes a continuation at most once, whoever gets there first (the work, a
/// second firing of SwiftUI's task, or cancellation); later calls are ignored.
/// A resume that arrives before the continuation is set is kept and delivered then.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending, !done { done = true; lock.unlock(); c.resume(with: pending); return }
        continuation = c
        lock.unlock()
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        guard let c = continuation else { pending = pending ?? result; lock.unlock(); return }
        done = true
        continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}

@available(macOS 26.0, *)
private struct TranslationBridge: View {
    let configuration: TranslationSession.Configuration
    let action: (TranslationSession) async -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(configuration) { session in await action(session) }
    }
}
