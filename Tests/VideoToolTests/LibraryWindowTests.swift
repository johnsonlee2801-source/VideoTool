import AppKit
import Testing
@testable import VideoTool

// Smoke tests for the AppKit library window: it builds, shows the controller's
// sections, renders cards, and opens a double-clicked video.

@Suite @MainActor struct LibraryWindowTests {
    private func makeController(withVideos names: [String]) throws -> (LibraryController, LibraryStore) {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("lw-\(UUID().uuidString).sqlite").path
        let store = try LibraryStore(path: db)
        _ = try store.addRoot("/m")
        for (i, n) in names.enumerated() {
            try store.upsert(MediaRecord(path: "/m/\(n)", fileKey: "k\(i)", size: 1, modified: Date(timeIntervalSince1970: 1_700_000_000),
                                         duration: Double(30 * (i + 1)), width: 1920, height: 1080, root: "/m"))
        }
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil },
                                  background: { _ in }, main: { $0() })
        return (c, store)
    }

    @Test("W1 the grid shows exactly the controller's sections and items") func gridMatchesController() throws {
        let (c, _) = try makeController(withVideos: ["a.mp4", "b.mkv", "c.mov"])
        let w = LibraryWindowController(controller: c, onOpen: { _ in })
        let grid = NSCollectionView()
        #expect(w.numberOfSections(in: grid) == 1)
        #expect(w.collectionView(grid, numberOfItemsInSection: 0) == 3)
        c.mode = .duration
        #expect(w.numberOfSections(in: grid) == c.sections.count)
    }

    @Test("W2 a card renders name, duration, resolution and stars") func card() throws {
        let (c, _) = try makeController(withVideos: ["clip.mp4"])
        var item = try #require(c.items.first)
        item.starCount = 2
        let card = LibraryCardItem()
        card.loadView()
        card.configure(item, thumbnail: URL(fileURLWithPath: "/nonexistent.jpg"))
        let texts = card.view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains("clip.mp4"))
        #expect(texts.contains { $0.contains("0:30") && $0.contains("1080p") && $0.contains("★2") })
    }

    @Test("W3 opening an item hands its file URL to the player") func open() throws {
        let (c, _) = try makeController(withVideos: ["clip.mp4"])
        var opened: URL?
        let w = LibraryWindowController(controller: c, onOpen: { opened = $0 })
        w.openForTesting(section: 0, item: 0)
        #expect(opened == URL(fileURLWithPath: "/m/clip.mp4"))
    }

    @Test("W4 an empty library explains how to start") func emptyState() throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("lw-\(UUID().uuidString).sqlite").path
        let c = LibraryController(store: try LibraryStore(path: db), stars: nil, makeIndexer: { nil },
                                  background: { _ in }, main: { $0() })
        let w = LibraryWindowController(controller: c, onOpen: { _ in })
        #expect(w.emptyMessageForTesting.contains("添加文件夹"))
        #expect(w.emptyMessageForTesting.contains("不会移动"))
    }
}
