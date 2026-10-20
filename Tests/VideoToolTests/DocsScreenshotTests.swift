import AppKit
import Testing
@testable import VideoTool

// README screenshots in Chinese, English and Japanese. Opt-in: runs only after
// tools/make_docs_screens.sh made the demo clips and touched the RUN marker.
// All footage is generated (fractals, gradients, cellular automata).

private let base = FileManager.default.temporaryDirectory.appendingPathComponent("videotool-docs")
private var requested: Bool {
    guard let date = (try? FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("RUN").path))?[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(date) < 600
}
private func clip(_ name: String) -> String { base.appendingPathComponent("clips/\(name).mp4").path }

private func frame(_ name: String, at t: Double) -> NSImage? {
    let url = base.appendingPathComponent("frames/\(name)-\(t).jpg")
    if !FileManager.default.fileExists(atPath: url.path) {
        _ = MPVFrameGrabber.grab(source: clip(name), start: String(t), thumbnailTo: url)
    }
    return NSImage(contentsOf: url)
}

/// The player's own subtitle file (ASS, translation above the original, thin band)
/// for bilingual cues given as (translation, original, start, end).
private func aiSubtitles(_ cues: [(String, String, Double, Double)], _ name: String) throws -> URL {
    let url = base.appendingPathComponent("frames/\(name).ass")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let doc = ASS.document(cues.map { SubtitleCue(start: $0.2, end: $0.3, text: $0.1, translation: $0.0) }, band: true)
    try doc.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// A frame with the AI subtitles drawn by the real renderer (libass), as the player shows them.
private func subtitledFrame(_ name: String, at t: Double, _ lines: [String], lang: String) throws -> NSImage? {
    let ass = try aiSubtitles([(lines[0], lines[1], 0, 600)], "still-\(lang)")
    let url = base.appendingPathComponent("frames/\(name)-\(t)-\(lang)-sub.jpg")
    _ = MPVFrameGrabber.grab(source: clip(name), start: String(t), thumbnailTo: url, subtitles: ass.path, width: nil)
    return NSImage(contentsOf: url)
}

@Suite(.serialized, .enabled(if: requested)) @MainActor struct DocsScreenshotTests {
    struct Copy {
        var lang: String, bundle: String
        var notes: [String]
        var subtitle: [String]                // translation, original
        var clipLines: [(String, String)]     // the demo GIF: translation, original
    }
    static let languages = [
        Copy(lang: "zh", bundle: "zh-Hans", notes: ["开场彩蛋", "", "名场面", "笑死", ""],
             subtitle: ["按住画面，就能加速播放。", "Press and hold the picture to speed up."],
             clipLines: [("看到喜欢的地方，按 B 打颗星。", "Press B to star the moment."),
                         ("两颗星之间，一键导出。", "Export what's between two stars."),
                         ("字幕也一起带走。", "The subtitles come along.")]),
        Copy(lang: "en", bundle: "en", notes: ["Opening easter egg", "", "Best scene", "LOL", ""],
             subtitle: ["Press and hold the picture to speed up.", "画面を長押しすると、速く再生できます。"],
             clipLines: [("Press B to star the moment.", "Bでいい場面にスターを。"),
                         ("Export what's between two stars.", "スターの間をそのまま書き出し。"),
                         ("The subtitles come along.", "字幕もいっしょに。")]),
        Copy(lang: "ja", bundle: "ja", notes: ["オープニングの小ネタ", "", "名場面", "爆笑", ""],
             subtitle: ["画面を長押しすると、速く再生できます。", "Press and hold the picture to speed up."],
             clipLines: [("Bでいい場面にスターを。", "Press B to star the moment."),
                         ("スターの間をそのまま書き出し。", "Export what's between two stars."),
                         ("字幕もいっしょに。", "The subtitles come along.")]),
    ]

    private func write(_ view: NSView, _ lang: String, _ name: String) throws {
        let dir = base.appendingPathComponent("out/\(lang)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded(); view.display()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func stars(_ c: Copy) -> [Bookmark] {
        zip([95.0, 410, 812, 1215, 1228], c.notes).map {
            Bookmark(id: UUID(), fileKey: "docs", time: $0.0, endTime: nil, note: $0.1, createdAt: Date())
        }
    }

    @Test("D1 screenshots in every language", arguments: languages.map(\.lang))
    func screenshots(lang: String) async throws {
        let c = try #require(Self.languages.first { $0.lang == lang })
        Localization.bundle = try #require(Localization.bundle(for: c.bundle))
        defer { Localization.bundle = .main }

        // 1. player: stars, hover preview, speed HUD, chosen speed 1.5×
        let saved = PreferredSpeedStore().speed
        PreferredSpeedStore().speed = 1.5
        defer { PreferredSpeedStore().speed = saved }
        do {
            let w = PlayerWindowController()
            defer { w.shutdown() }
            w.window?.setContentSize(NSSize(width: 1280, height: 772))
            w.stageForSnapshot(frame: frame("neon", at: 9), bookmarks: stars(c), duration: 1500, position: 640,
                               showList: false, previewFirst: true, hud: "2.6")
            try write(try #require(w.window?.contentView), lang, "player")
        }
        // 2. star list open
        do {
            let w = PlayerWindowController()
            defer { w.shutdown() }
            w.window?.setContentSize(NSSize(width: 1280, height: 772))
            w.stageForSnapshot(frame: frame("life", at: 7), bookmarks: stars(c), duration: 1500, position: 820,
                               showList: true, previewFirst: false, hud: nil)
            try write(try #require(w.window?.contentView), lang, "stars")
        }
        // 3. AI subtitles: bilingual lines on the picture and the progress card
        do {
            let w = PlayerWindowController()
            defer { w.shutdown() }
            w.window?.setContentSize(NSSize(width: 1280, height: 772))
            let picture = try #require(try subtitledFrame("aurora", at: 6, c.subtitle, lang: lang))
            w.stageForSnapshot(frame: picture, bookmarks: [], duration: 1500, position: 300,
                               showList: false, previewFirst: false, hud: nil)
            w.aiCard.finish(L("字幕已生成，共 %@ 句（按 S 可切换字幕）", "214"))
            try write(try #require(w.window?.contentView), lang, "ai-subtitles")
        }
        // 3b. an exported clip: a GIF with the AI subtitles burned in, made by the real exporter
        do {
            let start = 6.0, step = 1.2
            let cues = c.clipLines.enumerated().map { ($0.element.0, $0.element.1, start + Double($0.offset) * step,
                                                       start + Double($0.offset + 1) * step) }
            let ass = try aiSubtitles(cues, "clip-\(lang)")
            let out = base.appendingPathComponent("out/\(lang)/clip.gif")
            _ = try await ClipExporter.export(source: URL(fileURLWithPath: clip("neon")),
                                              range: ClipRange(start: start, end: start + step * Double(cues.count)),
                                              format: .gif, subtitles: ass, to: out)
        }
        // 4–5. library: continue watching, then by series
        let (window, controller) = try library()
        try write(try #require(window.window?.contentView), lang, "library")
        window.setModeForSnapshot(.series)
        try write(try #require(window.window?.contentView), lang, "series")
        _ = controller
        // 6. first launch
        do {
            let w = PlayerWindowController()
            defer { w.shutdown() }
            w.window?.setContentSize(NSSize(width: 1280, height: 772))
            try write(try #require(w.window?.contentView), lang, "welcome")
        }
    }

    private func library() throws -> (LibraryWindowController, LibraryController) {
        let db = TestTemp.directory.appendingPathComponent("docs-\(UUID().uuidString).sqlite").path
        let store = try LibraryStore(path: db)
        let thumbs = TestTemp.directory.appendingPathComponent("docsthumbs-\(UUID().uuidString)")
        let root = "/Volumes/Media/Videos"
        _ = try store.addRoot(root)
        let videos: [(String, String, Double, Double, Int, Int, [(String, Double)])] = [
            ("Neon Nights S01E01.mkv", "neon", 3, 1450, 3840, 2160, [("夜景", 0.9), ("城市", 0.8)]),
            ("Neon Nights S01E02.mkv", "neon", 7, 1392, 3840, 2160, [("夜景", 0.9)]),
            ("Neon Nights S01E03.mkv", "neon", 12, 1510, 3840, 2160, [("夜景", 0.9)]),
            ("Aurora Drift 4K.mov", "aurora", 4, 754, 3840, 2160, [("天空", 0.9), ("夜晚", 0.7)]),
            ("Game of Life — lecture 1.mp4", "life", 5, 3720, 1920, 1080, [("屏幕", 0.9), ("文字", 0.7)]),
            ("Game of Life — lecture 2.mp4", "life", 11, 3655, 1920, 1080, [("屏幕", 0.9)]),
            ("Rule 110 timelapse.mp4", "cells", 6, 188, 1920, 1080, [("艺术", 0.8)]),
            ("Aurora Drift (vertical).mp4", "aurora", 13, 42, 1080, 1920, [("天空", 0.9)]),
        ]
        let suite = "videotool-tests-docs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let history = WatchHistoryStore(defaults: defaults)
        for (i, v) in videos.enumerated() {
            let key = "docs-\(i)", path = "\(root)/\(v.0)"
            _ = MPVFrameGrabber.grab(source: clip(v.1), start: String(v.2), thumbnailTo: LibraryIndexer.thumbnailURL(forKey: key, in: thumbs))
            try store.upsert(MediaRecord(path: path, fileKey: key, size: 1, modified: Date(timeIntervalSince1970: 1_790_000_000 - Double(i) * 900_000),
                                         duration: v.3, width: v.4, height: v.5, root: root))
            try store.setTags(v.6, for: key, source: "vision")
        }
        history.markFinished(path: "\(root)/\(videos[0].0)", duration: videos[0].3)
        history.recordProgress(path: "\(root)/\(videos[1].0)", position: 610, duration: videos[1].3)
        history.recordProgress(path: "\(root)/\(videos[4].0)", position: 1500, duration: videos[4].3)
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, thumbnailDirectory: thumbs,
                                  background: { _ in }, main: { $0() }, history: history, series: SeriesOverrideStore(defaults: defaults))
        let w = LibraryWindowController(controller: c, onOpen: { _ in })
        w.window?.setContentSize(NSSize(width: 1280, height: 820))
        return (w, c)
    }
}
