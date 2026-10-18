import Foundation
import Testing
@testable import VideoTool

// Large-library stress run. Skipped unless tools/stress_library.sh has generated
// the library; writes measurements to stress-results.json next to it.

private let root = FileManager.default.temporaryDirectory.appendingPathComponent("videotool-stress/library").path
private func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

/// Runs only right after tools/stress_library.sh touched the marker (within 10 min),
/// so the generated library left in the temp dir never slows down normal test runs.
private var requested: Bool {
    let marker = (root as NSString).deletingLastPathComponent + "/RUN"
    guard let date = (try? FileManager.default.attributesOfItem(atPath: marker))?[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(date) < 600
}

@Suite(.enabled(if: requested)) struct StressTests {
    @Test("ST1 index a large library: first pass, incremental pass, grouping and search") func largeLibrary() throws {
        let dir = (root as NSString).deletingLastPathComponent
        let store = try LibraryStore(path: dir + "/stress-\(UUID().uuidString).sqlite")
        let thumbs = URL(fileURLWithPath: dir).appendingPathComponent("thumbs-\(UUID().uuidString)")
        _ = try store.addRoot(root)
        let indexer = LibraryIndexer(store: store, thumbnailDirectory: thumbs)
        let mem0 = residentMB()

        var t = Date()
        let first = indexer.index(root: root, progress: { _ in }, isCancelled: { false })
        let firstSeconds = Date().timeIntervalSince(t)
        let memAfter = residentMB()

        t = Date()
        let second = indexer.index(root: root, progress: { _ in }, isCancelled: { false })
        let secondSeconds = Date().timeIntervalSince(t)

        let rows = try store.media(inRoot: root)
        let tags = try store.allTags()
        let items = rows.map { LibraryItem(record: $0, tags: tags[$0.fileKey] ?? []) }
        t = Date()
        var sectionCount = 0
        for mode in LibraryGroupingMode.allCases { sectionCount += LibraryGrouping.sections(items, mode: mode).count }
        _ = LibraryGrouping.sections(items, mode: .all, search: "clip 0")
        let groupingSeconds = Date().timeIntervalSince(t)

        let results: [String: Any] = [
            "files": rows.count, "added": first.added, "unreadable": first.unreadable, "probeFailed": first.probeFailed,
            "firstPassSeconds": firstSeconds, "perFileMs": firstSeconds / Double(max(rows.count, 1)) * 1000,
            "secondPassSeconds": secondSeconds, "secondUnchanged": second.unchanged,
            "groupingAllModesSeconds": groupingSeconds, "sections": sectionCount,
            "memoryStartMB": mem0, "memoryAfterFirstPassMB": memAfter, "memoryEndMB": residentMB(),
        ]
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: dir + "/stress-results.json"))

        #expect(first.added == rows.count && first.unreadable == 0)
        #expect(second.unchanged == rows.count, "second pass must skip everything")
        #expect(secondSeconds < firstSeconds / 10, "incremental pass should be far cheaper")
        #expect(groupingSeconds < 2, "grouping \(rows.count) items in every mode")
    }
}
