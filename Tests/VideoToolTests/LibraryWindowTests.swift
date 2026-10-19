import AppKit
import Testing
@testable import VideoTool

// Smoke tests for the AppKit library window: it builds, shows the controller's
// sections, renders cards, and opens a double-clicked video.

@Suite @MainActor struct LibraryWindowTests {
    private func makeController(withVideos names: [String]) throws -> (LibraryController, LibraryStore) {
        let db = TestTemp.directory.appendingPathComponent("lw-\(UUID().uuidString).sqlite").path
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
        let texts = card.textsForTesting
        #expect(texts.contains("clip.mp4"))
        #expect(texts.contains("0:30"))
        #expect(texts.contains("HD"))
        #expect(texts.contains("★ 2"))
    }

    @Test("W3 opening an item hands its file URL to the player") func open() throws {
        let (c, _) = try makeController(withVideos: ["clip.mp4"])
        var opened: URL?
        let w = LibraryWindowController(controller: c, onOpen: { opened = $0 })
        w.openForTesting(section: 0, item: 0)
        #expect(opened == URL(fileURLWithPath: "/m/clip.mp4"))
    }

    @Test("W4 an empty library explains how to start") func emptyState() throws {
        let db = TestTemp.directory.appendingPathComponent("lw-\(UUID().uuidString).sqlite").path
        let c = LibraryController(store: try LibraryStore(path: db), stars: nil, makeIndexer: { nil },
                                  background: { _ in }, main: { $0() })
        let w = LibraryWindowController(controller: c, onOpen: { _ in })
        #expect(w.emptyMessageForTesting.contains("添加文件夹"))
        #expect(w.emptyMessageForTesting.contains("自动整理"))
        #expect(w.emptyMessageForTesting.contains("不会移动"))
    }

    @Test("W5 card width adapts to fill the row: more columns when wider, never narrower than the minimum")
    func adaptiveColumns() {
        let narrow = LibraryCardItem.layout(forWidth: 700)
        let wide = LibraryCardItem.layout(forWidth: 1600)
        #expect(wide.columns > narrow.columns)
        for l in [narrow, wide, LibraryCardItem.layout(forWidth: 300)] {
            #expect(l.itemSize.width >= LibraryCardItem.minWidth || l.columns == 1)
            #expect(abs(l.itemSize.height - (l.itemSize.width * 9 / 16 + LibraryCardItem.infoHeight)) < 0.5, "16:9 thumbnail")
        }
        let w = 1600.0, l = LibraryCardItem.layout(forWidth: w)
        let used = Double(l.columns) * l.itemSize.width + Double(l.columns - 1) * LibraryCardItem.spacing + 2 * LibraryCardItem.sideInset
        #expect(abs(used - w) < 1.5, "the row is filled edge to edge: \(used) vs \(w)")
    }
}
