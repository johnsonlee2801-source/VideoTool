import Foundation
import Testing
@testable import VideoTool

// Series grouping (2026-10-19): episodes of one show come together, in order.
// Reviews of other players: auto-organising must be correctable, and corrections
// must stick, so overrides are kept by content key (they survive moves/renames).
struct EpisodeParserTests {
    @Test("EP1 common naming styles", arguments: [
        ("Breaking.Bad.S02E05.1080p.BluRay.x264.mkv", "Breaking Bad", 2, 5, true),
        ("the office s1e03.mp4", "the office", 1, 3, true),
        ("Friends - 3x14 - The One with Phoebe.avi", "Friends", 3, 14, true),
        ("[Sakura] Frieren - 07 [1080p][CHS].mkv", "Frieren", nil, 7, false),
        ("[ANi] 葬送的芙莉莲 - 12 [1080P][Baha].mp4", "葬送的芙莉莲", nil, 12, false),
        ("繁花 第12集.mp4", "繁花", nil, 12, true),
        ("庆余年 第二季 第3集 4K.mp4", "庆余年", 2, 3, true),
        ("海贼王 第1080话.mkv", "海贼王", nil, 1080, true),
        ("Python入门 EP03 变量.mp4", "Python入门", nil, 3, true),
        ("Lecture Ep.11 - Graphs.mp4", "Lecture", nil, 11, true),
        ("Kurzgesagt E04.webm", "Kurzgesagt", nil, 4, true),
    ])
    func parses(name: String, title: String, season: Int?, episode: Int, strong: Bool) {
        let info = EpisodeParser.parse(name)
        #expect(info == EpisodeInfo(title: title, season: season, episode: episode, strong: strong), "\(name)")
    }

    @Test("EP2 names that are not episodes", arguments: [
        "Tokyo Night Walk 4K.mp4", "IMG_2024.MOV", "Concert 1920x1080.mkv", "Movie (2019).mkv",
        "vacation 720p.mp4", "Screen Recording 2026-10-18 at 21.03.11.mov", "Beach Day.mp4", "1080.mp4",
    ])
    func notEpisodes(name: String) {
        let info = EpisodeParser.parse(name)
        #expect(info == nil || info?.strong == false, "\(name) → \(String(describing: info))")
        if let info { #expect(![1920, 1080, 720, 2019, 2024, 2026].contains(info.episode), "\(name)") }
    }

    @Test("EP3 Chinese numerals for episodes and seasons") func chineseNumerals() {
        #expect(EpisodeParser.chineseNumber("十二") == 12)
        #expect(EpisodeParser.chineseNumber("二十") == 20)
        #expect(EpisodeParser.chineseNumber("一百零八") == 108)
        #expect(EpisodeParser.chineseNumber("两") == 2)
        #expect(EpisodeParser.parse("长相思 第十五集.mp4")?.episode == 15)
    }
}

private func item(_ name: String, key: String = UUID().uuidString, folder: String = "/m",
                  watch: WatchEntry? = nil) -> LibraryItem {
    LibraryItem(record: MediaRecord(path: "\(folder)/\(name)", fileKey: key, size: 1, modified: Date(timeIntervalSince1970: 1_790_000_000),
                                    duration: 1500, width: 1920, height: 1080, root: "/m"), tags: [], watch: watch)
}

struct SeriesGroupingTests {
    @Test("SG1 episodes of one show form one section, in episode order; season in the title")
    func groups() {
        let items = ["Breaking.Bad.S01E03.mkv", "Breaking.Bad.S01E01.mkv", "Breaking.Bad.S01E02.mkv",
                     "Breaking.Bad.S02E01.mkv", "Beach Day.mp4"].map { item($0) }
        let sections = LibraryGrouping.sections(items, mode: .series)
        #expect(sections.map(\.title) == ["Breaking Bad · 第 1 季 · 3 集", "Breaking Bad · 第 2 季 · 1 集", "其他视频"])
        #expect(sections[0].items.map(\.name) == ["Breaking.Bad.S01E01.mkv", "Breaking.Bad.S01E02.mkv", "Breaking.Bad.S01E03.mkv"])
    }

    @Test("SG2 weak matches (anime ' - 07') need at least two episodes; titles match ignoring case and dots")
    func weakNeedsCompany() {
        let one = LibraryGrouping.sections([item("Clip - 42.mp4")], mode: .series)
        #expect(one.map(\.title) == ["其他视频"])
        let two = LibraryGrouping.sections([item("[Sakura] Frieren - 07.mkv"), item("[Other] frieren - 08.mkv")], mode: .series)
        #expect(two.first?.title == "Frieren · 2 集")
    }

    @Test("SG3 a corrected file keeps its correction; 'not a series' moves it out") func overrides() {
        let a = item("random name.mp4", key: "k1"), b = item("Show S01E01.mp4", key: "k2"), c = item("Show S01E02.mp4", key: "k3")
        var ctx = SeriesContext()
        ctx.files["k1"] = SeriesOverride(title: "Show", season: 1, episode: 3)
        ctx.files["k3"] = SeriesOverride(excluded: true)
        let sections = LibraryGrouping.sections([a, b, c], mode: .series, series: ctx)
        #expect(sections.first?.title == "Show · 第 1 季 · 2 集")
        #expect(sections.first?.items.map(\.record.fileKey) == ["k2", "k1"])
        #expect(sections.last?.items.map(\.record.fileKey) == ["k3"])
    }

    @Test("SG4 renaming a show applies to every episode with that detected name") func aliases() {
        var ctx = SeriesContext()
        ctx.aliases[EpisodeParser.normalizedTitle("Sousou no Frieren")] = "葬送的芙莉莲"
        let sections = LibraryGrouping.sections([item("Sousou.no.Frieren.S01E01.mkv"), item("Sousou no Frieren S01E02.mkv")],
                                                mode: .series, series: ctx)
        #expect(sections.first?.title == "葬送的芙莉莲 · 第 1 季 · 2 集")
    }

    @Test("SG5 the info shown in the edit dialog: override first, else what was detected") func effectiveInfo() {
        var ctx = SeriesContext()
        #expect(ctx.info(for: item("Show S02E04.mp4", key: "k"))?.episode == 4)
        ctx.files["k"] = SeriesOverride(title: "Other", season: nil, episode: 9)
        #expect(ctx.info(for: item("Show S02E04.mp4", key: "k")) == EpisodeInfo(title: "Other", season: nil, episode: 9, strong: true))
        ctx.files["k"] = SeriesOverride(excluded: true)
        #expect(ctx.info(for: item("Show S02E04.mp4", key: "k")) == nil)
    }
}


struct SeriesOverrideStoreTests {
    @Test("SG6 corrections and show names persist") func persists() throws {
        let suite = "videotool-tests-sg-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let a = SeriesOverrideStore(defaults: d)
        a.set(SeriesOverride(title: "Show", season: 2, episode: 5), for: "k1")
        a.set(SeriesOverride(excluded: true), for: "k2")
        a.setAlias("葬送的芙莉莲", forDetected: "Sousou no Frieren")
        let ctx = SeriesOverrideStore(defaults: d).context
        #expect(ctx.files["k1"] == SeriesOverride(title: "Show", season: 2, episode: 5))
        #expect(ctx.files["k2"]?.excluded == true)
        #expect(ctx.aliases[EpisodeParser.normalizedTitle("sousou.no.frieren")] == "葬送的芙莉莲")
    }
}

struct WatchHistoryTests {
    @Test("WH1 progress is recorded per file; reaching the end marks it watched") func progress() throws {
        let suite = "videotool-tests-wh-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let h = WatchHistoryStore(defaults: d, now: { Date(timeIntervalSince1970: 100) })
        h.recordProgress(path: "/m/a.mp4", position: 300, duration: 1200)
        #expect(h.entry(for: "/m/a.mp4") == WatchEntry(position: 300, duration: 1200, watchedAt: Date(timeIntervalSince1970: 100), finished: false))
        #expect(abs((h.entry(for: "/m/a.mp4")?.fraction ?? 0) - 0.25) < 0.001)
        h.markFinished(path: "/m/a.mp4", duration: 1200)
        #expect(WatchHistoryStore(defaults: d).entry(for: "/m/a.mp4")?.finished == true)
        h.recordProgress(path: "/m/a.mp4", position: 20, duration: 1200)    // started again
        #expect(h.entry(for: "/m/a.mp4")?.finished == false)
    }

    @Test("WH2 within the last 10 s (or 97 %) counts as watched") func nearEnd() {
        #expect(WatchEntry(position: 1195, duration: 1200, watchedAt: .distantPast, finished: false).isWatched)
        #expect(WatchEntry(position: 300, duration: 1200, watchedAt: .distantPast, finished: false).isWatched == false)
        #expect(WatchEntry(position: 0, duration: 0, watchedAt: .distantPast, finished: true).isWatched)
    }

    @Test("WH3 the oldest entries are dropped beyond the cap") func cap() throws {
        let suite = "videotool-tests-wh-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var t = 0.0
        let h = WatchHistoryStore(defaults: d, maxEntries: 3, now: { t += 1; return Date(timeIntervalSince1970: t) })
        for p in ["/a", "/b", "/c", "/d"] { h.recordProgress(path: p, position: 30, duration: 100) }
        #expect(h.entry(for: "/a") == nil && h.entry(for: "/d") != nil)
    }
}

struct ContinueWatchingTests {
    private func w(_ pos: Double, _ at: Double, finished: Bool = false) -> WatchEntry {
        WatchEntry(position: pos, duration: 1500, watchedAt: Date(timeIntervalSince1970: at), finished: finished)
    }

    @Test("CW1 'all videos' starts with unfinished videos, most recent first") func continueRow() {
        let items = [item("a.mp4", watch: w(300, 10)), item("b.mp4", watch: w(600, 30)), item("c.mp4"),
                     item("d.mp4", watch: w(1500, 40, finished: true)), item("e.mp4", watch: w(2, 50)),
                     item("f.mp4", watch: w(1495, 60))]          // credits: counts as watched
        let sections = LibraryGrouping.sections(items, mode: .all)
        #expect(sections.map(\.title) == ["继续观看", "全部视频"])
        #expect(sections[0].items.map(\.name) == ["b.mp4", "a.mp4"], "finished and barely-started videos are left out")
        #expect(sections[1].items.count == 6)
    }

    @Test("CW2 no 'continue' row while searching or when nothing is in progress") func hidden() {
        let items = [item("a.mp4", watch: w(300, 10)), item("b.mp4")]
        #expect(LibraryGrouping.sections(items, mode: .all, search: "a").map(\.title) == ["全部视频"])
        #expect(LibraryGrouping.sections([item("b.mp4")], mode: .all).map(\.title) == ["全部视频"])
    }

    @Test("CW3 the row is capped") func capped() {
        let items = (0..<30).map { item("v\($0).mp4", watch: w(300, Double($0))) }
        #expect(LibraryGrouping.sections(items, mode: .all).first?.items.count == LibraryGrouping.continueWatchingLimit)
    }
}

@Suite(.serialized) @MainActor struct SeriesUITests {
    @Test("SG7 the edit form: a show name and an episode number are needed; season is optional")
    func form() {
        #expect(SeriesEditDialog.parse(title: " 繁花 ", season: "", episode: "12") == SeriesOverride(title: "繁花", season: nil, episode: 12))
        #expect(SeriesEditDialog.parse(title: "Show", season: "2", episode: "5") == SeriesOverride(title: "Show", season: 2, episode: 5))
        // Season 0 (specials, "S00E01") is kept: saving the prefilled form unchanged must not
        // move the episode out of its season (audit 2026-10-20).
        #expect(SeriesEditDialog.parse(title: "Show", season: "0", episode: "5")?.season == 0)
        #expect(SeriesEditDialog.parse(title: "Show", season: "", episode: "5")?.season == nil)
        #expect(SeriesEditDialog.parse(title: "", season: "1", episode: "5") == nil)
        #expect(SeriesEditDialog.parse(title: "Show", season: "1", episode: "five") == nil)
    }

    @Test("SG8 a correction made through the controller regroups at once, and renaming covers the whole show")
    func controllerSaves() throws {
        let store = try LibraryStore(path: TestTemp.directory.appendingPathComponent("sg8-\(UUID().uuidString).sqlite").path)
        _ = try store.addRoot("/m")
        for (i, n) in ["Sousou.no.Frieren.S01E01.mkv", "Sousou.no.Frieren.S01E02.mkv", "random.mp4"].enumerated() {
            try store.upsert(MediaRecord(path: "/m/\(n)", fileKey: "k\(i)", size: 1, modified: Date(), duration: 60,
                                         width: 1920, height: 1080, root: "/m"))
        }
        let suite = "videotool-tests-sg8-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let c = LibraryController(store: store, stars: nil, makeIndexer: { nil }, background: { $0() }, main: { $0() },
                                  history: WatchHistoryStore(defaults: d), series: SeriesOverrideStore(defaults: d))
        c.mode = .series
        let first = try #require(c.items.first { $0.record.fileKey == "k0" })
        c.saveSeries(SeriesOverride(title: "葬送的芙莉莲", season: 1, episode: 1), for: first, renameShow: true)
        #expect(c.sections.first?.title == "葬送的芙莉莲 · 第 1 季 · 2 集")
        let random = try #require(c.items.first { $0.record.fileKey == "k2" })
        c.saveSeries(SeriesOverride(title: "葬送的芙莉莲", season: 1, episode: 3), for: random)
        #expect(c.sections.first?.title == "葬送的芙莉莲 · 第 1 季 · 3 集")
        #expect(c.sections.count == 1)
    }

    @Test("SG9 a cover shows how far it was watched, or a tick when finished") func cardProgress() {
        let card = LibraryCardItem()
        _ = card.view
        let base = MediaRecord(path: "/m/a.mp4", fileKey: "k", size: 1, modified: Date(), duration: 1200, width: 1920, height: 1080, root: "/m")
        card.configure(LibraryItem(record: base, tags: [], watch: WatchEntry(position: 300, duration: 1200, watchedAt: Date(), finished: false)),
                       thumbnail: URL(fileURLWithPath: "/nonexistent.jpg"))
        #expect(card.textsForTesting.contains("25%") && !card.textsForTesting.contains("✓ 已看完"))
        card.configure(LibraryItem(record: base, tags: [], watch: WatchEntry(position: 1200, duration: 1200, watchedAt: Date(), finished: true)),
                       thumbnail: URL(fileURLWithPath: "/nonexistent.jpg"))
        #expect(card.textsForTesting.contains("✓ 已看完") && !card.textsForTesting.contains { $0.hasSuffix("%") })
        card.configure(LibraryItem(record: base, tags: []), thumbnail: URL(fileURLWithPath: "/nonexistent.jpg"))
        #expect(!card.textsForTesting.contains("✓ 已看完") && !card.textsForTesting.contains { $0.hasSuffix("%") })
    }
}


// Full-codebase audit 2026-10-20 (batch 03).
struct SeriesAuditTests {
    @Test("EP9 digits from other scripts (Arabic-Indic ٢) never crash the parser")
    func otherDigits() {
        for name in ["Show EP٢.mkv", "Show S٠١E٠٢.mkv", "Show ٠١x٠٢.mkv", "Show - ٠٧.mkv", "Show 第٣集.mp4"] {
            _ = EpisodeParser.parse(name)                        // used to force-unwrap Int("٢") == nil
        }
        #expect(EpisodeParser.parse("Show S01E02.mkv")?.episode == 2)
    }

    @Test("EP10 a country qualifier is part of the show; years and release tags are not")
    func qualifiers() {
        let us = EpisodeParser.parse("The Office (US) S01E01.mkv"), uk = EpisodeParser.parse("The Office (UK) S01E01.mkv")
        #expect(us != nil && uk != nil)
        #expect(EpisodeParser.normalizedTitle(us!.title) != EpisodeParser.normalizedTitle(uk!.title))
        #expect(EpisodeParser.parse("Show (2019) S01E01.mkv")?.title == "Show")
        #expect(EpisodeParser.parse("Show (1080p) S01E01.mkv")?.title == "Show")
    }
}
