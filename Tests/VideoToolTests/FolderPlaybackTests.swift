import Foundation
import Testing
@testable import VideoTool

@Suite struct FolderPlaybackTests {
    @Test("FP1 directory listing is shallow, regular-media-only and naturally ordered")
    func shallow() throws {
        let dir = TestTemp.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub/fake.mp4"), withIntermediateDirectories: true)
        for name in ["10.mp4", "2.mkv", "1.mp4", "notes.txt", "sub/3.mp4"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let result = try FolderDirectory.read(dir.path)
        #expect(result.videos.map { ($0 as NSString).lastPathComponent } == ["1.mp4", "2.mkv", "10.mp4"])
        #expect(result.folders == [dir.appendingPathComponent("sub").path])
    }

    @Test("FP2 previous and next stay in the same directory and never wrap")
    func neighbors() {
        let q = FolderPlaybackQueue(read: { _ in FolderDirectory(folders: [], videos: ["/a/10.mp4", "/a/1.mp4", "/a/2.mp4", "/ab/3.mp4"]) },
                                    background: { $0() }, main: { $0() })
        q.load("/a/2.mp4")
        #expect(q.previous == "/a/1.mp4" && q.next == "/a/10.mp4")
        q.load("/a/1.mp4"); #expect(q.previous == nil)
        q.load("/a/10.mp4"); #expect(q.next == nil)
        q.load("/a/missing.mp4"); #expect(q.previous == nil && q.next == nil)
    }

    @Test("FP3 an older directory request cannot replace the new file's neighbors; shutdown discards results")
    func stale() {
        var jobs: [() -> Void] = []
        let q = FolderPlaybackQueue(read: { path in FolderDirectory(folders: [], videos: [path + "/1.mp4", path + "/2.mp4"]) },
                                    background: { jobs.append($0) }, main: { $0() })
        q.load("/a/1.mp4"); q.load("/b/1.mp4")
        jobs[1](); jobs[0]()
        #expect(q.next == "/b/2.mp4")
        q.load("/c/1.mp4"); q.shutdown(); jobs[2]()
        #expect(q.next == nil && q.previous == nil)
    }

    @Test("FP4 directory failures clear old navigation without changing the current file")
    func errors() {
        let q = FolderPlaybackQueue(read: { path in
            if path == "/bad" { throw CocoaError(.fileReadNoSuchFile) }
            return FolderDirectory(folders: [], videos: ["/a/1.mp4", "/a/2.mp4"])
        }, background: { $0() }, main: { $0() })
        q.load("/a/1.mp4"); #expect(q.next != nil)
        q.load("/bad/1.mp4")
        #expect(q.next == nil && q.previous == nil && q.error != nil)
    }
}
