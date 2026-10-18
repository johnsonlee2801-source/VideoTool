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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-\(seconds).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = MPVFrameGrabber.grab(source: fixture, start: String(seconds), thumbnailTo: url)
        }
        return NSImage(contentsOf: url)
    }
}

@Suite(.serialized) @MainActor struct UISnapshotTests {
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
        w.libraryOffer.offer("/Volumes/Media/北海道旅行 2026")
        try Snapshot.write(try #require(w.window?.contentView), "P4-player-library-offer")
        w.libraryOffer.press(.add)
        try Snapshot.write(try #require(w.window?.contentView), "P4b-player-library-added")
    }

    private func library(empty: Bool = false) throws -> LibraryWindowController {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).sqlite").path
        let store = try LibraryStore(path: db)
        let thumbs = FileManager.default.temporaryDirectory.appendingPathComponent("snapthumbs-\(UUID().uuidString)")
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
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, thumbnailDirectory: thumbs,
                                  background: { _ in }, main: { $0() })
        let w = LibraryWindowController(controller: c, onOpen: { _ in })
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

    @Test("L3 library: empty") func libraryEmpty() throws {
        let w = try library(empty: true)
        try Snapshot.write(try #require(w.window?.contentView), "L3-library-empty")
    }
}
