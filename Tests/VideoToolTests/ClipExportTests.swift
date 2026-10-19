import AppKit
import AVFoundation
import ImageIO
import Testing
@testable import VideoTool

// Exporting the part between two stars as an MP4 clip, a GIF or a set of stills
// (2026-10-19). Real libmpv encoding and frame grabs: integration lane.

private final class Marker {}
private func fixture(_ name: String, _ ext: String) -> URL {
    URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: name, ofType: ext)!)
}
private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
private func outDir() throws -> URL {
    let d = TestTemp.directory.appendingPathComponent("clip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct ClipRangeTests {
    @Test("CE1 the suggested range runs from the star before the playhead to the next one",
          arguments: [
            // position, stars, duration → start, end
            (8.0, [5.0, 12, 18], 20.0, 5.0, 12.0),
            (5.0, [5.0, 12, 18], 20.0, 5.0, 12.0),     // standing on a star
            (2.0, [5.0, 12, 18], 20.0, 2.0, 5.0),      // before the first star: from here
            (19.0, [5.0, 12, 18], 20.0, 18.0, 20.0),   // after the last star: to the end
            (3.0, [], 60.0, 3.0, 13.0),                // no stars: ten seconds from here
            (55.0, [], 60.0, 55.0, 60.0),              // …but not past the end
          ])
    func suggested(_ c: (Double, [Double], Double, Double, Double)) {
        let r = ClipRange.suggested(position: c.0, stars: c.1, duration: c.2)
        #expect(r == ClipRange(start: c.3, end: c.4))
    }

    @Test("CE1b times typed as 1:02:03, 2:05 or 7.5 are understood; nonsense is not")
    func parse() {
        #expect(TimeFormatting.parse("1:02:03") == 3723)
        #expect(TimeFormatting.parse("2:05") == 125)
        #expect(TimeFormatting.parse(" 7.5 ") == 7.5)
        #expect(TimeFormatting.parse("0:00") == 0)
        #expect(TimeFormatting.parse("abc") == nil)
        #expect(TimeFormatting.parse("1:75") == nil)
        #expect(TimeFormatting.parse("") == nil)
        #expect(TimeFormatting.parse("-3") == nil)
    }

    @Test("CE1c a range must have a length and stay inside the video; GIFs are capped")
    func validation() {
        #expect(ClipRange(start: 5, end: 5).problem(duration: 20, format: .video) != nil)
        #expect(ClipRange(start: 8, end: 5).problem(duration: 20, format: .video) != nil)
        #expect(ClipRange(start: 5, end: 25).problem(duration: 20, format: .video) != nil)
        #expect(ClipRange(start: 0, end: 20).problem(duration: 20, format: .video) == nil)
        #expect(ClipRange(start: 0, end: ClipExporter.maxGIFLength + 1).problem(duration: 600, format: .gif) != nil)
        #expect(ClipRange(start: 0, end: ClipExporter.maxGIFLength).problem(duration: 600, format: .gif) == nil)
    }
}

@Suite(.serialized) struct ClipExporterTests {
    @Test("CE2 an MP4 clip of an MKV: H.264 + AAC, the right length, opens in AVFoundation (QuickTime, Photos, chat apps)")
    func mp4() async throws {
        let out = try outDir().appendingPathComponent("clip.mp4")
        let urls = try await ClipExporter.export(source: fixture("av1_opus", "mkv"), range: ClipRange(start: 0.5, end: 2.5),
                                                 format: .video, to: out)
        #expect(urls == [out])
        let asset = AVURLAsset(url: out)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 2) < 0.35, "duration \(seconds)")
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(!audio.isEmpty, "keeps the sound")
        let codec = try await video.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_H264)
    }

    @Test("CE3 a GIF: 10 frames a second, 480 pixels wide, loops")
    func gif() async throws {
        let out = try outDir().appendingPathComponent("clip.gif")
        _ = try await ClipExporter.export(source: fixture("testsrc-20s", "mp4"), range: ClipRange(start: 2, end: 4),
                                          format: .gif, to: out)
        let src = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetType(src) as String? == "com.compuserve.gif")
        let n = CGImageSourceGetCount(src)
        #expect((18...22).contains(n), "frames: \(n)")
        let first = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(first.width == 480)
        let props = CGImageSourceCopyProperties(src, nil) as? [String: Any]
        let gifProps = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        #expect(gifProps?[kCGImagePropertyGIFLoopCount as String] as? Int == 0, "loops forever")
        // testsrc has a moving counter, so the first and last frames differ.
        let last = try #require(CGImageSourceCreateImageAtIndex(src, n - 1, nil))
        #expect(first.dataProvider?.data as Data? != last.dataProvider?.data as Data?)
    }

    @Test("CE4 stills: evenly spread JPEGs at full size, named by time, in the chosen folder")
    func stills() async throws {
        let dir = try outDir()
        let urls = try await ClipExporter.export(source: fixture("testsrc-20s", "mp4"), range: ClipRange(start: 2, end: 12),
                                                 format: .stills(count: 6), to: dir.appendingPathComponent("Show"))
        #expect(urls.map(\.lastPathComponent) == ["Show 0-02.jpg", "Show 0-04.jpg", "Show 0-06.jpg",
                                                  "Show 0-08.jpg", "Show 0-10.jpg", "Show 0-12.jpg"])
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL })
        for u in urls {
            let img = try #require(NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(img.width == 640, "full width of the 640×360 source")
        }
    }

    @Test("CE5 a file that cannot be read fails with a reason and leaves nothing behind")
    func failure() async throws {
        let dir = try outDir()
        let bad = dir.appendingPathComponent("not-a-video.mp4")
        try Data("hello".utf8).write(to: bad)
        let out = dir.appendingPathComponent("clip.mp4")
        await #expect(throws: ClipExporter.Failure.self) {
            _ = try await ClipExporter.export(source: bad, range: ClipRange(start: 0, end: 1), format: .video, to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}

@Suite(.serialized) @MainActor struct ClipExportPlayerTests {
    @Test("CE6 the player offers Play › Export Clip once a video is open, and suggests the range around the playhead")
    func playerHook() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let item = NSMenuItem(title: "", action: #selector(PlayerWindowController.exportClip(_:)), keyEquivalent: "")
        #expect(w.validateMenuItem(item) == false, "nothing open")
        // A copy: opening the shared fixture would leave per-video memory behind for other suites.
        let copy = try outDir().appendingPathComponent("clip-source.mp4")
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: copy)
        w.open(copy)
        let engine = try #require(w.engine)
        #expect(await waitUntil { w.loadedPath != nil })
        engine.setPaused(true)
        engine.seek(to: 4)
        #expect(await waitUntil { abs(engine.state.timePos - 4) < 0.2 })
        #expect(w.validateMenuItem(item))
        let pos = engine.state.timePos
        #expect(w.suggestedClipRange() == ClipRange(start: pos, end: min(pos + 10, engine.state.duration)))
    }
}
