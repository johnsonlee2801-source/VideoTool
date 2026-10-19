import AppKit
import Testing
@testable import VideoTool
import VideoToolCore

// Findings of the TDD review of 9312ca5..5dd554b (2026-10-19). Each test was
// written to fail on the code as reviewed, then the code was fixed.

private final class Marker {}
private let sample = URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: "testsrc-20s", ofType: "mp4")!)

@MainActor
private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Recognises nothing until the test lets it go, then returns `result`.
final class GatedRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var started = 0
    let result: Result<[SpeechSegment], Error>
    init(_ result: Result<[SpeechSegment], Error>) { self.result = result }

    func transcribe(audio: URL, locale: String, duration: Double,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock(); started += 1
            if released { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
        return try result.get()
    }

    func release() {
        lock.lock(); released = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
}

private let speech = [SpeechSegment(text: "Hello, everyone.", start: 0, end: 1.2, words: [])]
private func pipeline(_ rec: SpeechRecognizing) -> AISubtitlePipeline {
    let dir = TestTemp.directory.appendingPathComponent("rf-\(UUID().uuidString)")
    return AISubtitlePipeline(recognizer: rec, translator: nil, cacheDirectory: dir, extract: { _, wav, _, _ in
        try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: 100).write(to: wav)
        return .success(3)
    })
}

private func button(_ title: String, in view: NSView) -> NSButton? {
    for v in view.subviews {
        if let b = v as? NSButton, b.title.contains(title) || b.attributedTitle.string.contains(title) { return b }
        if let b = button(title, in: v) { return b }
    }
    return nil
}

@Suite(.serialized) @MainActor struct AIJobLifecycleTests {
    @Test("RF1 a cancelled job that fails late cannot touch the job started after it") func lateFailure() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let old = GatedRecognizer(.failure(AISubtitleError.failed("late")))
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: pipeline(old))
        #expect(await waitUntil { old.started == 1 })
        try #require(button("取消", in: w.aiCard)).performClick(nil)
        #expect(!w.isMakingAISubtitles)

        let new = GatedRecognizer(.success(speech))
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: pipeline(new))
        #expect(await waitUntil { new.started == 1 })
        old.release()                                    // the old job now fails, late
        try await Task.sleep(for: .milliseconds(200))
        #expect(w.isMakingAISubtitles, "the new job must still be running and cancellable")
        #expect(!w.aiCard.message.contains("失败"), "card: \(w.aiCard.message)")
        new.release()
        #expect(await waitUntil { !w.isMakingAISubtitles })
        #expect(w.aiCard.message.contains("字幕已生成"))
    }

    @Test("RF2 starting a job while one runs cancels the first; never two at once") func secondStart() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let first = GatedRecognizer(.success(speech)), second = GatedRecognizer(.success(speech))
        let p1 = pipeline(first)
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: p1)
        #expect(await waitUntil { first.started == 1 })
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: pipeline(second))
        #expect(p1.isCancelled)
        first.release(); second.release()
        #expect(await waitUntil { !w.isMakingAISubtitles })
    }

    @Test("RF3 while the language dialog is being prepared or shown, 'AI 字幕…' is not offered again")
    func dialogPending() async throws {
        guard #available(macOS 26.0, *) else { return }
        let w = PlayerWindowController()
        defer { w.window?.attachedSheet.map { w.window?.endSheet($0) }; w.shutdown() }
        w.open(sample)
        let item = NSMenuItem(title: "AI 字幕…", action: #selector(PlayerWindowController.generateAISubtitles(_:)), keyEquivalent: "")
        #expect(w.validateMenuItem(item))
        w.generateAISubtitles(nil)
        #expect(!w.validateMenuItem(item), "a second ⌘T would queue a second dialog")
    }

    @Test("RF4 the card's 取消 button itself cancels the job") func cancelButton() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(sample)
        let rec = GatedRecognizer(.success(speech))
        let p = pipeline(rec)
        w.startAISubtitles(video: sample.path, choice: .init(source: "en-US", target: nil), pipeline: p)
        #expect(await waitUntil { rec.started == 1 })
        try #require(button("取消", in: w.aiCard)).performClick(nil)
        #expect(p.isCancelled && !w.isMakingAISubtitles && w.aiCard.message == "已取消生成字幕")
        rec.release()
    }

    @Test("RF5 generating again for subtitles already loaded does not add a second track") func noDuplicateTrack() async throws {
        let srt = TestTemp.directory.appendingPathComponent("rf5-\(UUID().uuidString).srt")
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "Hi")]).write(to: srt, atomically: true, encoding: .utf8)
        let engine = try MPVEngine()
        let layer = MPVRenderLayer(engine: engine)              // vo=libmpv needs a render context to load
        defer { layer.teardown(); engine.shutdown() }
        var loaded = false
        engine.onEvent = { if case .fileLoaded = $0 { loaded = true } }
        engine.loadTarget(sample.path)
        #expect(await waitUntil { loaded })
        engine.addSubtitle(path: srt.path, title: "AI 字幕（英语）")
        #expect(await waitUntil { engine.trackCounts().subtitle == 1 })
        engine.addSubtitle(path: srt.path, title: "AI 字幕（英语）")
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.trackCounts().subtitle == 1)
    }
}

struct PipelineCancellationTests {
    @Test("RF6 any error after cancelling counts as cancelled (recogniser or translator)") func lateErrors() async throws {
        final class FailAfterCancel: SpeechRecognizing, @unchecked Sendable {
            var pipeline: AISubtitlePipeline?
            func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] {
                pipeline?.cancel()
                throw CancellationError()
            }
        }
        let rec = FailAfterCancel()
        let p = pipeline(rec); rec.pipeline = p
        await #expect(throws: AISubtitleError.cancelled) { try await p.run(.init(video: "/v", source: "en-US", target: nil), progress: { _, _ in }) }

        final class Gen: SpeechRecognizing, @unchecked Sendable {
            func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] { speech }
        }
        final class CancelInTranslation: SubtitleTranslating, @unchecked Sendable {
            var pipeline: AISubtitlePipeline?
            func translate(_ lines: [String], from: String, to: String) async throws -> [String] {
                pipeline?.cancel(); throw AISubtitleError.translationUnavailable
            }
        }
        let tr = CancelInTranslation()
        let dir = TestTemp.directory.appendingPathComponent("rf6-\(UUID().uuidString)")
        let p2 = AISubtitlePipeline(recognizer: Gen(), translator: tr, cacheDirectory: dir, extract: { _, wav, _, _ in
            try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(count: 100).write(to: wav); return .success(3)
        })
        tr.pipeline = p2
        await #expect(throws: AISubtitleError.cancelled) { try await p2.run(.init(video: "/v", source: "en-US", target: "zh-Hans"), progress: { _, _ in }) }
        // Recognition had finished, so its result is kept for a retry; no translated file is written.
        #expect(!FileManager.default.fileExists(atPath: SubtitleCache.url(forVideo: "/v", source: "en-US", target: "zh-Hans", in: dir).path),
                "a cancelled translation writes no translated subtitle file")
    }

    @Test("RF7 when translation is skipped the file is the original-only one, without translations") func skippedFile() async throws {
        final class Gen: SpeechRecognizing, @unchecked Sendable {
            func transcribe(audio: URL, locale: String, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechSegment] { speech }
        }
        final class NoTranslation: SubtitleTranslating, @unchecked Sendable {
            func translate(_ lines: [String], from: String, to: String) async throws -> [String] { throw AISubtitleError.translationUnavailable }
        }
        let dir = TestTemp.directory.appendingPathComponent("rf7-\(UUID().uuidString)")
        let p = AISubtitlePipeline(recognizer: Gen(), translator: NoTranslation(), cacheDirectory: dir, extract: { _, wav, _, _ in
            try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(count: 100).write(to: wav); return .success(3)
        })
        let out = try await p.run(.init(video: "/v/a.mkv", source: "en-US", target: "ja"), progress: { _, _ in })
        #expect(out.srt == SubtitleCache.url(forVideo: "/v/a.mkv", source: "en-US", target: nil, in: dir))
        #expect(try String(contentsOf: out.srt, encoding: .utf8) == SRT.document([SubtitleCue(start: 0, end: 1.2, text: "Hello, everyone.")]))
    }
}

struct SmallFindingTests {
    @Test("RF8 adding the disk root takes in every library folder (no nested folders left)") func diskRoot() throws {
        let s = try LibraryStore(path: TestTemp.directory.appendingPathComponent("rf8-\(UUID().uuidString).sqlite").path)
        _ = try s.addRoot("/m/a")
        #expect(try s.addRoot("/") == .absorbed(["/m/a"]))
        #expect(try s.roots() == ["/"])
        #expect(try s.addRoot("/m/b") == .alreadyCovered(by: "/"))
    }

    @Test("RF9 iCloud Drive folders are offered (the drive itself as 'this layer only')") func iCloudDrive() {
        let drive = "/home/u/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(LibraryOffer.proposal(forFile: drive + "/电影/a.mp4", roots: [], declined: [], neverAsk: false, home: "/home/u")
                == .init(path: drive + "/电影", wholeFolder: true))
        #expect(LibraryOffer.proposal(forFile: drive + "/a.mp4", roots: [], declined: [], neverAsk: false, home: "/home/u")
                == .init(path: drive, wholeFolder: false))
        #expect(LibraryOffer.proposal(forFile: "/home/u/Library/Containers/x/a.mp4", roots: [], declined: [], neverAsk: false,
                                      home: "/home/u") == nil)
    }

    @Test("RF10 two outputs with the same name are both offered") func sameNamedOutputs() {
        let devices = [AudioDevice(name: "auto", description: "Autoselect"),
                       AudioDevice(name: "coreaudio/AA-11", description: "AirPods"),
                       AudioDevice(name: "coreaudio/BB-22", description: "AirPods"),
                       AudioDevice(name: "avfoundation/AA-11", description: "AirPods")]
        #expect(AudioOutput.choices(from: devices).map(\.name) == ["auto", "coreaudio/AA-11", "coreaudio/BB-22"])
    }

    @Test("RF11 multi-episode files (S01E01E02, S01E01-E02) are read as their first episode") func multiEpisode() {
        #expect(EpisodeParser.parse("Show.S01E01E02.mkv") == EpisodeInfo(title: "Show", season: 1, episode: 1, strong: true))
        #expect(EpisodeParser.parse("Show S02E03-E04 1080p.mkv") == EpisodeInfo(title: "Show", season: 2, episode: 3, strong: true))
    }

    @Test("RF12 the default drag curve is the agreed one (golden values, not compared with itself)") func goldenCurve() {
        let o = SpeedGestureOptions.defaults
        for (dx, speed) in [(0.0, 2.0), (8, 2.0), (28, 2.1), (-28, 1.9), (208, 3.0), (218, 3.1), (508, 6.0), (-5000, 0.5)] {
            #expect(abs(SpeedCurve.speed(forDrag: dx, options: o) - speed) < 1e-9, "dx \(dx)")
            #expect(abs(SpeedCurve.speed(forDrag: dx, options: o, origin: 2.0) - speed) < 1e-9, "dx \(dx), origin 2.0")
        }
    }

    @Test("RF13 law: for every hold start, the drag curve rises with dx, stays in range, and has no jump")
    func curveLaw() {
        let o = SpeedGestureOptions.defaults
        for origin in stride(from: 2.0, through: 6.0, by: 0.1) {
            var last = -Double.infinity
            for dx in stride(from: -2000.0, through: 2000, by: 1) {
                let s = SpeedCurve.speed(forDrag: dx, options: o, origin: origin)
                #expect(s >= last - 1e-9 && s >= o.minSpeed && s <= o.maxSpeed, "origin \(origin) dx \(dx)")
                #expect(s - last <= 0.1 + 1e-9 || last == -.infinity, "jump at origin \(origin) dx \(dx): \(last) → \(s)")
                last = s
            }
        }
    }
}

struct ResumeOnceTests {
    @Test("RF14 a continuation is resumed once: the first result wins, later ones are ignored") func firstWins() async throws {
        let once = ResumeOnce<Int>()
        let value = try await withCheckedThrowingContinuation { c in
            once.set(c)
            once.resume(.success(1))
            once.resume(.success(2))                         // e.g. SwiftUI firing the task again
            once.resume(.failure(AISubtitleError.cancelled))  // or a late cancel
        }
        #expect(value == 1)
    }

    @Test("RF15 cancellation arriving before the work starts is delivered when the wait begins") func earlyCancel() async {
        let once = ResumeOnce<Int>()
        once.resume(.failure(AISubtitleError.cancelled))
        await #expect(throws: AISubtitleError.cancelled) {
            try await withCheckedThrowingContinuation { c in once.set(c); once.resume(.success(3)) }
        }
    }
}

@Suite(.serialized) @MainActor struct ReviewFindingUITests {
    @Test("RF16 the offer card's real buttons report add / not this one / never") func offerButtons() throws {
        let bar = LibraryOfferBar()
        var log: [String] = []
        bar.onAdd = { log.append("add \($0.path)") }
        bar.onDecline = { log.append("decline \($0)") }
        bar.onNeverAsk = { log.append("never") }
        bar.onOpenLibrary = { log.append("open") }
        bar.offer(.init(path: "/m/a", wholeFolder: true))
        try #require(button("加入", in: bar)).performClick(nil)
        try #require(button("打开视频库", in: bar)).performClick(nil)
        bar.offer(.init(path: "/m/b", wholeFolder: true))
        try #require(button("不加", in: bar)).performClick(nil)
        bar.offer(.init(path: "/m/c", wholeFolder: true))
        try #require(button("不再询问", in: bar)).performClick(nil)
        #expect(log == ["add /m/a", "open", "decline /m/b", "never"])
    }

    @Test("RF17 coming back to the library window shows what was watched meanwhile (继续观看 is not stale)")
    func refreshOnFocus() throws {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("rf17-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        try store.upsert(MediaRecord(path: "/m/a.mp4", fileKey: "k", size: 1, modified: Date(), duration: 1200,
                                     width: 1920, height: 1080, root: "/m"))
        let suite = "videotool-tests-rf17-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let history = WatchHistoryStore(defaults: d)
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { _ in }, main: { $0() }, history: history)
        let w = LibraryWindowController(controller: c, onOpen: { _ in })
        #expect(c.sections.map(\.title) == ["全部视频"])
        history.recordProgress(path: "/m/a.mp4", position: 300, duration: 1200)     // watched in the player meanwhile
        w.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: w.window))
        #expect(c.sections.map(\.title) == ["继续观看", "全部视频"])
    }
}
