import AppKit
import Testing
@testable import VideoTool

// Renders the main screens to PNG so the UI can be reviewed without a person
// at the screen. Output: $VIDEOTOOL_SNAPSHOT_DIR, default
// ~/Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex/snapshots/<label>/
// These tests assert only that rendering works; the images are for review.

private final class Marker {}
private let fixture = Bundle(for: Marker.self).path(forResource: "testsrc-20s", ofType: "mp4")!

@MainActor
enum Snapshot {
    static var directory: URL = {
        let base = ProcessInfo.processInfo.environment["VIDEOTOOL_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex/snapshots")
        let label = ProcessInfo.processInfo.environment["VIDEOTOOL_SNAPSHOT_LABEL"] ?? "current"
        let dir = base.appendingPathComponent(label)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @discardableResult
    static func write(_ view: NSView, _ name: String) throws -> URL {
        view.layoutSubtreeIfNeeded()
        view.display()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    static func frame(at seconds: Double) -> NSImage? {
        let url = TestTemp.directory.appendingPathComponent("snapframe-\(seconds).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = MPVFrameGrabber.grab(source: fixture, start: String(seconds), thumbnailTo: url)
        }
        return NSImage(contentsOf: url)
    }
}

@Suite(.serialized) @MainActor struct UISnapshotTests {
    @Test("P8 network video entry sheet fits compact controls and Chinese status text")
    func networkVideoEntry() throws {
        let sheet = NetworkVideoSheet { _ in }
        defer { sheet.cancel() }
        sheet.urlField.stringValue = "https://www.youtube.com/watch?v=M7lc1UVf-VE"
        sheet.status.stringValue = L("正在解析视频，可随时取消…")
        try Snapshot.write(try #require(sheet.panel.contentView), "P8-network-video")
    }
    @Test("P9 Bilibili parts stay compact at 280 and 380 points")
    func biliParts() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        w.sidebar.show(.stars)
        w.sidebar.setNetworkParts((1...23).map { BilibiliPart(page: $0, title: "第\($0)集 · 播放器演示与使用说明") }, current: 2, onSelect: nil)
        for width in [280.0, 380.0] {
            w.sidebar.resize(to: width)
            w.window?.contentView?.layoutSubtreeIfNeeded()
            try Snapshot.write(w.sidebar, "P9-bilibili-parts-\(Int(width))")
        }
    }
    @Test("P10 network buffering and recovery controls stay compact")
    func networkRecovery() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let fixture = try #require(Bundle(for: SnapshotFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let media = ResolvedNetworkVideo(request: try NetworkVideo("https://youtu.be/M7lc1UVf-VE"), title: "Network", videoURL: fixture, audioURL: nil, headers: [:])
        w.openNetwork(media)
        w.engine?.onEvent?(.playbackFailed(path: fixture.path))
        w.window?.setContentSize(NSSize(width: 800, height: 500))
        try Snapshot.write(try #require(w.window?.contentView), "P10-network-retry")
    }
    @Test("P11 compact continue row and separate online history at 280 and 380 points")
    func continueWatching() throws {
        let name = "videotool-tests-continue-snapshot-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let network = NetworkWatchHistoryStore(defaults: defaults)
        network.record(try NetworkVideo("https://bilibili.com/video/BV1bK411W797?p=3"), title: "课程第三集 · 实践与复习", position: 758, duration: 1800)
        let w = PlayerWindowController(history: WatchHistoryStore(defaults: defaults), networkHistory: network)
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        w.sidebar.show(.recent)
        let recent = w.sidebar.recent
        recent.sourceSelector.selectedSegment = 1
        NSApp.sendAction(recent.sourceSelector.action!, to: recent.sourceSelector.target, from: recent.sourceSelector)
        for width in [280.0, 380.0] {
            w.sidebar.resize(to: width)
            w.window?.contentView?.layoutSubtreeIfNeeded()
            let list = try #require(recent.networkView)
            let first = try #require(list.playButtons.first)
            let row = first.convert(first.bounds, to: list)
            #expect(row.intersects(list.bounds) && row.maxY > list.bounds.maxY - 60, "online history must start at the top and remain visible")
            try Snapshot.write(w.sidebar, "P11-continue-\(Int(width))")
        }
    }
    @Test("P12 precise clip adjustment fits a compact popover")
    func clipAdjustment() throws {
        var selection = ClipSelection(); _ = selection.mark(65.25); _ = selection.mark(72.5)
        let view = ClipAdjustmentView(range: try #require(selection.range), duration: 180, fps: 24) { selection.adjust($0, to: $1, duration: 180) }
        try Snapshot.write(view, "P12-clip-adjustment")
    }
    private func stars() -> [Bookmark] {
        [(62.0, "开场彩蛋"), (305, ""), (611, "这段笑死"), (1180, "名场面"), (1190, "")].map {
            Bookmark(id: UUID(), fileKey: "k", time: $0.0, endTime: nil, note: $0.1, createdAt: Date())
        }
    }

    @Test("P1 player: empty state") func playerEmpty() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        try Snapshot.write(try #require(w.window?.contentView), "P1-player-empty")
    }

    @Test("P2 player: playing with stars, hover preview and speed HUD") func playerStars() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        w.stageForSnapshot(frame: Snapshot.frame(at: 6), bookmarks: stars(), duration: 1500, position: 420,
                           showList: false, previewFirst: true, hud: "2.4")
        try Snapshot.write(try #require(w.window?.contentView), "P2-player-stars")
    }

    @Test("P3 player: star list open") func playerList() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        w.stageForSnapshot(frame: Snapshot.frame(at: 12), bookmarks: stars(), duration: 1500, position: 615,
                           showList: true, previewFirst: false, hud: nil)
        try Snapshot.write(try #require(w.window?.contentView), "P3-player-list")
    }

    @Test("P4 player: 'add this folder to the library?' card") func playerLibraryOffer() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        w.stageForSnapshot(frame: Snapshot.frame(at: 6), bookmarks: [], duration: 1500, position: 30,
                           showList: false, previewFirst: false, hud: nil)
        w.libraryOffer.offer(.init(path: "/Volumes/Media/北海道旅行 2026", wholeFolder: true))
        try Snapshot.write(try #require(w.window?.contentView), "P4-player-library-offer")
        w.libraryOffer.press(.add)
        try Snapshot.write(try #require(w.window?.contentView), "P4b-player-library-added")
    }

    private func library(empty: Bool = false) throws -> LibraryTestHost {
        let db = TestTemp.directory.appendingPathComponent("snap-\(UUID().uuidString).sqlite").path
        let store = try LibraryStore(path: db)
        let thumbs = TestTemp.directory.appendingPathComponent("snapthumbs-\(UUID().uuidString)")
        if !empty {
            _ = try store.addRoot("/Volumes/Media/Movies")
            let names = ["Tokyo Night Walk 4K.mp4", "猫猫日常 vlog.mov", "Concert – encore.mkv", "Beach Day.mp4",
                         "旅行/北海道 Day 3.mp4", "旅行/北海道 Day 4.mp4", "Tutorial – SwiftUI basics.mp4", "Clip 0042.mp4"]
            for (i, n) in names.enumerated() {
                let key = "k\(i)"
                let thumb = LibraryIndexer.thumbnailURL(forKey: key, in: thumbs)
                _ = MPVFrameGrabber.grab(source: fixture, start: String(Double(i * 2 + 1)), thumbnailTo: thumb)
                try store.upsert(MediaRecord(path: "/Volumes/Media/Movies/\(n)", fileKey: key, size: 1,
                                             modified: Date(timeIntervalSince1970: 1_790_000_000 - Double(i) * 2_600_000),
                                             duration: [42, 754, 3720, 188, 1310, 1288, 905, 12][i],
                                             width: [3840, 1920, 1920, 1280, 1920, 1920, 2560, 640][i],
                                             height: [2160, 1080, 1080, 720, 1080, 1080, 1440, 360][i],
                                             root: "/Volumes/Media/Movies"))
                try store.setTags([[("夜景", 0.9), ("城市", 0.8)], [("猫", 0.95)], [("演出", 0.9), ("人群", 0.7)],
                                   [("海滩", 0.9), ("户外", 0.6)], [("雪", 0.9), ("户外", 0.8)], [("雪", 0.8)],
                                   [("屏幕", 0.9), ("文字", 0.7)], []][i], for: key, source: "vision")
            }
        }
        // Some watch progress, so covers show stripes, a tick and a 继续观看 row.
        let history = WatchHistoryStore(defaults: UserDefaults(suiteName: "videotool-tests-snap-\(UUID().uuidString)")!)
        if !empty {
            let base = "/Volumes/Media/Movies/"
            history.recordProgress(path: base + "猫猫日常 vlog.mov", position: 300, duration: 754)
            history.markFinished(path: base + "旅行/北海道 Day 3.mp4", duration: 1310)
            history.recordProgress(path: base + "旅行/北海道 Day 4.mp4", position: 260, duration: 1288)
        }
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, thumbnailDirectory: thumbs,
                                  background: { _ in }, main: { $0() }, history: history)
        let w = LibraryTestHost(controller: c, onOpen: { _ in })
        w.window?.setContentSize(NSSize(width: 1180, height: 760))
        return w
    }

    @Test("L1 library: all videos") func libraryAll() throws {
        let w = try library()
        try Snapshot.write(try #require(w.window?.contentView), "L1-library-all")
    }

    @Test("L2 library: by tag") func libraryTags() throws {
        let w = try library()
        w.setModeForSnapshot(.tag)
        try Snapshot.write(try #require(w.window?.contentView), "L2-library-tags")
    }

    @Test("L4 library: by series") func librarySeries() throws {
        let w = try library()
        w.setModeForSnapshot(.series)
        try Snapshot.write(try #require(w.window?.contentView), "L4-library-series")
    }

    @Test("L3 library: empty") func libraryEmpty() throws {
        let w = try library(empty: true)
        try Snapshot.write(try #require(w.window?.contentView), "L3-library-empty")
    }

    @Test("P5 player: embedded library, recent playback and stars share the right sidebar")
    func unifiedSidebar() throws {
        let fixture = try library()
        let suite = "videotool-tests-sidebar-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = WatchHistoryStore(defaults: defaults)
        for item in fixture.model.items {
            guard let watch = item.watch else { continue }
            if watch.isWatched { history.markFinished(path: item.record.path, duration: watch.duration) }
            else { history.recordProgress(path: item.record.path, position: watch.position, duration: watch.duration) }
        }
        let w = PlayerWindowController(libraryProvider: { fixture.model }, history: history)
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1280, height: 720))
        w.stageForSnapshot(frame: Snapshot.frame(at: 8), bookmarks: stars(), duration: 1500, position: 420,
                           showList: false, previewFirst: false, hud: nil)
        for (tab, name) in [(PlayerSidebarTab.library, "P5a-sidebar-library"), (.recent, "P5b-sidebar-recent"), (.stars, "P5c-sidebar-stars")] {
            w.sidebar.show(tab)
            try Snapshot.write(try #require(w.window?.contentView), name)
        }
        w.window?.setContentSize(NSSize(width: 520, height: 560))
        w.sidebar.show(.library)
        try Snapshot.write(try #require(w.window?.contentView), "P5d-sidebar-narrow")
    }

    @Test("P6 player: empty embedded library explains how to add folders")
    func emptySidebar() throws {
        let fixture = try library(empty: true)
        let w = PlayerWindowController(libraryProvider: { fixture.model })
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1100, height: 660))
        w.showLibrary(nil)
        try Snapshot.write(try #require(w.window?.contentView), "P6-sidebar-empty")
    }

    @Test("P7 folder-first sidebar: compact rows at 280, 380 and 560 points")
    func folderSidebar() throws {
        let fixture = try library()
        let w = PlayerWindowController(libraryProvider: { fixture.model })
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1280, height: 720))
        w.showLibrary(nil)
        let folders = try #require(w.sidebar.libraryBrowser?.folderBrowser)
        folders.enter("/Volumes/Media/Movies")
        w.sidebar.currentPath = "/Volumes/Media/Movies/猫猫日常 vlog.mov"
        for width in [280.0, 380.0, 560.0] {
            w.sidebar.resize(to: width)
            w.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(w.sidebar.bounds.width - width) < 1)
            #expect(folders.visibleFolders.count == 1 && folders.visibleVideos.count == 6)
            try Snapshot.write(w.sidebar, "P7-folders-\(Int(width))")
        }
        folders.enter("/Volumes/Media/Movies/旅行")
        try Snapshot.write(w.sidebar, "P7b-folder-child")
        w.window?.setContentSize(NSSize(width: 520, height: 560))
        try Snapshot.write(try #require(w.window?.contentView), "P7c-player-small-folder")
    }
}

private final class SnapshotFixtureMarker {}
