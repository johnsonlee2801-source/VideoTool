import Foundation
import Testing
@testable import VideoTool

// Star bookmarks follow the file's content, not its name. Large files use the
// OpenSubtitles hash (size + first/last 64 KB); expected values below were
// computed with an independent Python implementation of the published algorithm.

private final class Marker {}
private let fixture = Bundle(for: Marker.self).path(forResource: "testsrc-20s", ofType: "mp4")!

private func tempFile(_ bytes: [UInt8], name: String = UUID().uuidString) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url.path
}

@Suite struct FileFingerprintTests {
    @Test("F1 matches the reference OSHash for the fixture video") func fixtureHash() throws {
        #expect(try FileFingerprint.compute(path: fixture) == "osh:58658fd4882cf11c")
    }

    @Test("F2 matches the reference OSHash for a synthetic 200 000-byte file") func syntheticHash() throws {
        let p = try tempFile((0..<200_000).map { UInt8($0 % 251) })
        #expect(try FileFingerprint.compute(path: p) == "osh:e19d5212c9812cd6")
    }

    @Test("F3 renaming or moving the file keeps the same key") func renameInvariant() throws {
        let p = try tempFile((0..<200_000).map { UInt8($0 % 7) }, name: "a.mp4")
        let before = try FileFingerprint.compute(path: p)
        let moved = (p as NSString).deletingLastPathComponent + "/renamed 新名字.mkv"
        try FileManager.default.moveItem(atPath: p, toPath: moved)
        #expect(try FileFingerprint.compute(path: moved) == before)
    }

    @Test("F4 changing a byte in the first or last 64 KB changes the key") func contentSensitive() throws {
        var bytes = (0..<300_000).map { UInt8($0 % 13) }
        let base = try FileFingerprint.compute(path: try tempFile(bytes))
        bytes[10] ^= 0xFF
        let head = try FileFingerprint.compute(path: try tempFile(bytes))
        bytes[10] ^= 0xFF; bytes[299_990] ^= 0xFF
        let tail = try FileFingerprint.compute(path: try tempFile(bytes))
        #expect(head != base)
        #expect(tail != base)
    }

    @Test("F5 files below 128 KB use a full-content SHA-256 key") func smallFiles() throws {
        let a = try FileFingerprint.compute(path: try tempFile([1, 2, 3]))
        let b = try FileFingerprint.compute(path: try tempFile([1, 2, 4]))
        #expect(a.hasPrefix("sha:") && a.count == 4 + 64)
        #expect(a != b)
        #expect(a == (try FileFingerprint.compute(path: try tempFile([1, 2, 3]))))
    }

    @Test("F6 a missing file throws instead of returning a key") func missingFile() {
        #expect(throws: (any Error).self) { try FileFingerprint.compute(path: "/nonexistent/\(UUID()).mp4") }
    }

    @Test("F7 non-file targets (streams, URLs) get a stable url: key") func urlKey() {
        #expect(FileFingerprint.key(forTarget: "https://example.com/v.m3u8") == "url:https://example.com/v.m3u8")
        #expect(FileFingerprint.key(forTarget: "/nonexistent/\(UUID()).mp4") == nil)
        #expect(FileFingerprint.key(forTarget: fixture) == "osh:58658fd4882cf11c")
    }

    @Test("F8 a file:// URL string gets the same content key as its plain path") func fileURLKey() {
        #expect(FileFingerprint.key(forTarget: URL(fileURLWithPath: fixture).absoluteString) == "osh:58658fd4882cf11c")
    }
}
