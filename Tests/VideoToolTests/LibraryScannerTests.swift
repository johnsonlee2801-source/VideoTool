import Foundation
import Testing
@testable import VideoTool

private func tree(_ files: [String: Int]) throws -> String {
    let root = TestTemp.directory.appendingPathComponent("scan-\(UUID().uuidString)").path
    for (rel, size) in files {
        let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
    }
    return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
}

@Suite struct LibraryScannerTests {
    @Test("S1 finds videos recursively, ignores audio and non-media, returns sorted paths with sizes")
    func findsVideos() throws {
        let root = try tree(["a.mp4": 10, "sub/b.MKV": 20, "sub/deep/c.mov": 30,
                             "song.mp3": 5, "notes.txt": 5, "sub/cover.jpg": 5])
        let found = LibraryScanner.scan(root: root).files
        #expect(found.map { String($0.path.dropFirst(root.count + 1)) } == ["a.mp4", "sub/b.MKV", "sub/deep/c.mov"])
        #expect(found.map(\.size) == [10, 20, 30])
    }

    @Test("S2 skips hidden files and folders and app/bundle packages") func skipsHidden() throws {
        let root = try tree(["ok.mp4": 1, ".hidden.mp4": 1, ".cache/x.mp4": 1, "Tool.app/Contents/demo.mp4": 1,
                             "Lib.photoslibrary/originals/y.mov": 1])
        #expect(LibraryScanner.scan(root: root).files.map { ($0.path as NSString).lastPathComponent } == ["ok.mp4"])
    }

    @Test("S3 a missing root yields nothing; cancellation stops early") func edgeCases() throws {
        #expect(LibraryScanner.scan(root: "/nonexistent/\(UUID())").files.isEmpty)
        let root = try tree(Dictionary(uniqueKeysWithValues: (0..<50).map { ("v\($0).mp4", 1) }))
        var checks = 0
        let found = LibraryScanner.scan(root: root, isCancelled: { checks += 1; return checks > 5 }).files
        #expect(found.count < 50)
    }

    @Test("S4 reports modification dates") func dates() throws {
        let root = try tree(["a.mp4": 1])
        let p = root + "/a.mp4"
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: p)
        #expect(LibraryScanner.scan(root: root).files.first?.modified == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("S5 a missing root or a file instead of a folder is reported as incomplete") func incompleteRoot() throws {
        #expect(!LibraryScanner.scan(root: "/nonexistent/\(UUID())").complete)
        let root = try tree(["a.mp4": 1])
        #expect(!LibraryScanner.scan(root: root + "/a.mp4").complete)
        #expect(LibraryScanner.scan(root: root).complete)
    }

    @Test("S6 an unreadable subfolder makes the walk incomplete (so nothing gets removed)") func unreadableSubfolder() throws {
        let root = try tree(["a.mp4": 1, "locked/b.mp4": 1])
        let locked = root + "/locked"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let r = LibraryScanner.scan(root: root)
        #expect(!r.complete)
        #expect(r.files.map { ($0.path as NSString).lastPathComponent } == ["a.mp4"])
    }

    @Test("S7 paths keep the root exactly as given: unresolved /var spelling and a trailing slash") func rootSpelling() throws {
        let made = try tree(["sub/a.mp4": 1])
        let short = made.hasPrefix("/private/") ? String(made.dropFirst("/private".count)) : made
        #expect(short.hasPrefix("/var/"), "temp dir should live under /var (a symlink to /private/var) on macOS")
        for root in [short, "/private" + short, short + "/"] {
            let found = LibraryScanner.scan(root: root).files
            let base = root.hasSuffix("/") ? String(root.dropLast()) : root
            #expect(found.map(\.path) == [base + "/sub/a.mp4"], "root spelled \(root)")
            #expect(found.first.map { LibraryGrouping.folderTitle(path: $0.path, root: root) } == "sub")
        }
    }

    @Test("S8 symbolic links are not followed, so a link loop terminates") func symlinkLoop() throws {
        let root = try tree(["a/v.mp4": 1])
        try FileManager.default.createSymbolicLink(atPath: root + "/a/loop", withDestinationPath: root + "/a")
        try FileManager.default.createSymbolicLink(atPath: root + "/link.mp4", withDestinationPath: root + "/a/v.mp4")
        let r = LibraryScanner.scan(root: root)
        #expect(r.files.map { String($0.path.dropFirst(root.count + 1)) } == ["a/v.mp4"])
        #expect(r.complete)
    }
}
