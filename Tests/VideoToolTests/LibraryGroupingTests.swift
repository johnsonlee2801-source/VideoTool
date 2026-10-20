import Foundation
import Testing
@testable import VideoTool

private func item(_ path: String, key: String? = nil, duration: Double = 60, w: Int = 1920, h: Int = 1080,
                  modified: String = "2026-10-01", tags: [String] = [], root: String = "/m") -> LibraryItem {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return LibraryItem(record: MediaRecord(path: path, fileKey: key ?? path, size: 1, modified: f.date(from: modified)!,
                                           duration: duration, width: w, height: h, root: root), tags: tags)
}
private let shanghai: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }()

@Suite struct LibraryGroupingTests {
    @Test("G1 duration buckets, boundaries included in the lower bucket") func durationBuckets() {
        #expect(LibraryGrouping.durationBucket(0) == .unknown)
        #expect(LibraryGrouping.durationBucket(59.9) == .underOneMinute)
        #expect(LibraryGrouping.durationBucket(60) == .underOneMinute)
        #expect(LibraryGrouping.durationBucket(61) == .oneToTen)
        #expect(LibraryGrouping.durationBucket(600) == .oneToTen)
        #expect(LibraryGrouping.durationBucket(1800) == .tenToThirty)
        #expect(LibraryGrouping.durationBucket(3600) == .thirtyToSixty)
        #expect(LibraryGrouping.durationBucket(3601) == .overAnHour)
    }

    @Test("G2 resolution buckets use the frame's short side (portrait videos too)") func resolutionBuckets() {
        #expect(LibraryGrouping.resolutionBucket(width: 3840, height: 2160) == .uhd)
        #expect(LibraryGrouping.resolutionBucket(width: 2160, height: 3840) == .uhd)
        #expect(LibraryGrouping.resolutionBucket(width: 1920, height: 1080) == .fullHD)
        #expect(LibraryGrouping.resolutionBucket(width: 1920, height: 800) == .fullHD, "scope 2.4:1 counts as 1080p")
        #expect(LibraryGrouping.resolutionBucket(width: 1280, height: 720) == .hd)
        #expect(LibraryGrouping.resolutionBucket(width: 640, height: 360) == .sd)
        #expect(LibraryGrouping.resolutionBucket(width: 0, height: 0) == .unknown)
    }

    @Test("G3 folder titles are relative to the library root") func folderTitles() {
        #expect(LibraryGrouping.folderTitle(path: "/m/旅行/2024/a.mp4", root: "/m") == "旅行/2024")
        #expect(LibraryGrouping.folderTitle(path: "/m/a.mp4", root: "/m") == "（根目录）")
    }

    @Test("G4 by date: newest month first, one section per month") func byDate() {
        let items = [item("/m/a.mp4", modified: "2026-09-03"), item("/m/b.mp4", modified: "2026-10-20"),
                     item("/m/c.mp4", modified: "2026-10-01")]
        let s = LibraryGrouping.sections(items, mode: .date, calendar: shanghai)
        #expect(s.map(\.title) == ["2026 年 10 月", "2026 年 9 月"])
        #expect(s[0].items.map(\.name) == ["b.mp4", "c.mp4"].sorted())
    }

    @Test("G5 by duration and resolution: fixed order, empty buckets omitted") func byBuckets() {
        let items = [item("/m/long.mp4", duration: 7200), item("/m/clip.mp4", duration: 30, w: 640, h: 360),
                     item("/m/ep.mp4", duration: 1500, w: 3840, h: 2160)]
        #expect(LibraryGrouping.sections(items, mode: .duration).map(\.title) == ["1 分钟以内", "10–30 分钟", "1 小时以上"])
        #expect(LibraryGrouping.sections(items, mode: .resolution).map(\.title) == ["4K 及以上", "1080p", "标清"])
    }

    @Test("G6 duplicates: only content keys with 2+ paths, largest group first") func duplicates() {
        let items = [item("/m/a.mp4", key: "k1"), item("/m/copy/a.mp4", key: "k1"), item("/m/b.mp4", key: "k2"),
                     item("/m/x.mkv", key: "k3"), item("/m/y.mkv", key: "k3"), item("/m/z.mkv", key: "k3")]
        let s = LibraryGrouping.sections(items, mode: .duplicates)
        #expect(s.map(\.items.count) == [3, 2])
        #expect(s.first?.title == "x.mkv 等 3 份相同内容")
    }

    @Test("G7 by tag: a video appears under each of its tags; untagged collected last") func byTag() {
        let items = [item("/m/a.mp4", tags: ["户外", "人物"]), item("/m/b.mp4", tags: ["户外"]), item("/m/c.mp4")]
        let s = LibraryGrouping.sections(items, mode: .tag)
        #expect(s.map(\.title) == ["户外", "人物", "未识别"])
        #expect(s[0].items.count == 2)
    }

    @Test("G8 search matches file name or tag, case-insensitive, before grouping") func search() {
        let items = [item("/m/Beach Day.mp4"), item("/m/b.mp4", tags: ["海滩"]), item("/m/c.mp4")]
        #expect(LibraryGrouping.sections(items, mode: .all, search: "beach").flatMap(\.items).map(\.name) == ["Beach Day.mp4"])
        #expect(LibraryGrouping.sections(items, mode: .all, search: "海滩").flatMap(\.items).map(\.name) == ["b.mp4"])
        #expect(LibraryGrouping.sections(items, mode: .all, search: "  ").flatMap(\.items).count == 3)
    }

    @Test("G9 all: a single section with a count; items sorted by name (localized)") func all() {
        let items = [item("/m/b.mp4"), item("/m/A.mp4"), item("/m/c.mp4")]
        let s = LibraryGrouping.sections(items, mode: .all)
        #expect(s.map(\.title) == ["全部视频"], "the count is shown as a badge in the header")
        #expect(s[0].items.map(\.name) == ["A.mp4", "b.mp4", "c.mp4"])
    }

    @Test("G10 every mode with no items yields no sections") func empty() {
        for mode in LibraryGroupingMode.allCases { #expect(LibraryGrouping.sections([], mode: mode).isEmpty, "\(mode)") }
    }

    @Test("G11 files with no usable date go to 日期未知, listed last") func unknownDate() {
        var old = item("/m/old.mp4"); old.record.modified = .distantPast
        let s = LibraryGrouping.sections([item("/m/a.mp4"), old], mode: .date, calendar: shanghai)
        #expect(s.map(\.title) == ["2026 年 10 月", "日期未知"])
    }

    @Test("G12 same file name in two folders sorts deterministically by full path") func tieBreak() {
        let a = item("/m/z/clip.mp4"), b = item("/m/a/clip.mp4")
        #expect(LibraryGrouping.sections([a, b], mode: .all)[0].items.map(\.record.path) == ["/m/a/clip.mp4", "/m/z/clip.mp4"])
        #expect(LibraryGrouping.sections([b, a], mode: .all) == LibraryGrouping.sections([a, b], mode: .all))
    }

    @Test("G13 duplicates need the same content check too (OSHash collisions are not duplicates)") func collision() {
        var x = item("/m/x.mp4", key: "osh:same"), y = item("/m/y.mp4", key: "osh:same")
        x.record.contentCheck = "c1"; y.record.contentCheck = "c2"
        #expect(LibraryGrouping.sections([x, y], mode: .duplicates).isEmpty)
        y.record.contentCheck = "c1"
        #expect(LibraryGrouping.sections([x, y], mode: .duplicates).count == 1)
    }

    @Test("G14 laws over random libraries: partitions conserve items, order of input never matters, search narrows")
    func laws() {
        var rng = SystemRandomNumberGenerator()
        let words = ["trip", "Trip", "家", "clip", "a", "b"]
        for _ in 0..<150 {
            let items: [LibraryItem] = (0..<Int.random(in: 0...25, using: &rng)).map { i in
                var it = item("/m/\(["x", "y/z", "旅行"].randomElement(using: &rng)!)/\(words.randomElement(using: &rng)!)\(i).mp4",
                              key: "k\(Int.random(in: 0...6, using: &rng))",
                              duration: Double.random(in: 0...8000, using: &rng),
                              w: [0, 640, 1280, 1920, 3840].randomElement(using: &rng)!, h: [0, 360, 720, 1080, 2160].randomElement(using: &rng)!,
                              modified: "2026-0\(Int.random(in: 1...9, using: &rng))-1\(Int.random(in: 0...9, using: &rng))",
                              tags: Array(["户外", "人物", "猫"].shuffled(using: &rng).prefix(Int.random(in: 0...2, using: &rng))))
                it.record.contentCheck = "c"
                return it
            }
            for mode in [LibraryGroupingMode.all, .folder, .date, .duration, .resolution] {
                let s = LibraryGrouping.sections(items, mode: mode, calendar: shanghai)
                #expect(s.flatMap(\.items).map(\.record.path).sorted() == items.map(\.record.path).sorted(), "\(mode) partition")
                #expect(LibraryGrouping.sections(items.shuffled(using: &rng), mode: mode, calendar: shanghai) == s, "\(mode) order-free")
            }
            for mode in LibraryGroupingMode.allCases {
                #expect(LibraryGrouping.sections(items.shuffled(using: &rng), mode: mode, calendar: shanghai) ==
                        LibraryGrouping.sections(items, mode: mode, calendar: shanghai), "\(mode) order-free")
            }
            let wide = Set(LibraryGrouping.sections(items, mode: .all, search: "t").flatMap(\.items).map(\.record.path))
            let narrow = Set(LibraryGrouping.sections(items, mode: .all, search: "tr").flatMap(\.items).map(\.record.path))
            #expect(narrow.isSubset(of: wide))
        }
    }
}


// Full-codebase audit 2026-10-20 (batch 03).
struct LibraryGroupingAuditTests {
    @Test("G20 folders with the same name in different library folders stay apart")
    func sameNameFolders() {
        let items = [item("/Volumes/A/Videos/Trips/a.mp4", root: "/Volumes/A/Videos"),
                     item("/Volumes/B/Videos/Trips/b.mp4", root: "/Volumes/B/Videos"),
                     item("/Volumes/A/Videos/c.mp4", root: "/Volumes/A/Videos"),
                     item("/Volumes/B/Videos/d.mp4", root: "/Volumes/B/Videos")]
        let sections = LibraryGrouping.sections(items, mode: .folder)
        #expect(sections.count == 4, "\(sections.map(\.title))")
        #expect(Set(sections.map(\.title)).count == 4, "titles tell them apart: \(sections.map(\.title))")
    }

    @Test("G21 months sort by date whatever the calendar (Japanese era years restart at 1)")
    func japaneseCalendar() {
        var cal = Calendar(identifier: .japanese); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let items = [item("/m/old.mp4", modified: "2018-06-15"), item("/m/new.mp4", modified: "2020-06-15")]
        let sections = LibraryGrouping.sections(items, mode: .date, calendar: cal)
        #expect(sections.map { $0.items.map(\.name) } == [["new.mp4"], ["old.mp4"]], "newest first")
    }

    @Test("G22 two copies of one weakly named episode are not a series")
    func duplicateWeakEpisode() {
        let items = [item("/m/a/Holiday - 07.mp4"), item("/m/b/Holiday - 07.mp4")]
        let sections = LibraryGrouping.sections(items, mode: .series)
        #expect(sections.map(\.title) == [L("其他视频")])
    }
}
