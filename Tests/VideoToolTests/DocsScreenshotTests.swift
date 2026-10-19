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

/// The frame with two subtitle lines burnt in the way the player shows them
/// (translation above the original), for the AI subtitle screenshot.
private func withSubtitles(_ image: NSImage, _ lines: [String]) -> NSImage {
    let size = NSSize(width: 1920, height: 1080)
    return NSImage(size: size, flipped: false) { rect in
        image.draw(in: rect)
        var y: CGFloat = 70
        let font = NSFont.systemFont(ofSize: 54, weight: .semibold)
        for line in lines.reversed() {
            // Two passes like the player's subtitles: a dark outline, then the white text on top.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6); shadow.shadowBlurRadius = 8; shadow.shadowOffset = .zero
            let outline = NSAttributedString(string: line, attributes: [
                .font: font, .strokeColor: NSColor.black.withAlphaComponent(0.85), .strokeWidth: 12, .shadow: shadow])
            let fill = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.white])
            let s = fill.size()
            let at = NSPoint(x: (rect.width - s.width) / 2, y: y)
            outline.draw(at: at)
            fill.draw(at: at)
            y += s.height + 4
        }
        return true
    }
}

@Suite(.serialized, .enabled(if: requested)) @MainActor struct DocsScreenshotTests {
    struct Copy {
        var lang: String, bundle: String
        var notes: [String]
        var subtitle: [String]                // translation, original
    }
    static let languages = [
        Copy(lang: "zh", bundle: "zh-Hans", notes: ["开场彩蛋", "", "名场面", "笑死", ""],
             subtitle: ["按住画面，就能加速播放。", "Press and hold the picture to speed up."]),
        Copy(lang: "en", bundle: "en", notes: ["Opening easter egg", "", "Best scene", "LOL", ""],
             subtitle: ["Press and hold the picture to speed up.", "画面を長押しすると、速く再生できます。"]),
        Copy(lang: "ja", bundle: "ja", notes: ["オープニングの小ネタ", "", "名場面", "爆笑", ""],
             subtitle: ["画面を長押しすると、速く再生できます。", "Press and hold the picture to speed up."]),
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
            let picture = try #require(frame("aurora", at: 6))
            w.stageForSnapshot(frame: withSubtitles(picture, c.subtitle), bookmarks: [], duration: 1500, position: 300,
                               showList: false, previewFirst: false, hud: nil)
            w.aiCard.finish(L("字幕已生成，共 %@ 句（按 S 可切换字幕）", "214"))
            try write(try #require(w.window?.contentView), lang, "ai-subtitles")
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
