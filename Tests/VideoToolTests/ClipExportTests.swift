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
            (5.03, [5.0, 12, 18], 20.0, 5.0, 12.0),    // a jump to a star lands a hair late
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
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["not-a-video.mp4"], "no half-written or hidden temp files: \(left)")
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

// MARK: clips with the AI subtitles burned in

/// An ASS "subtitle" that paints the bottom third solid red for the first minute:
/// easy to detect in a frame, and unlike any subtitle a file brings itself.
private func redBandSubtitles() throws -> URL {
    let url = TestTemp.directory.appendingPathComponent("red-\(UUID().uuidString).ass")
    try """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,40,&H000000FF,&H000000FF,&H000000FF,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:01:00.00,Default,,0,0,0,,{\\pos(0,240)\\p1}m 0 0 l 640 0 640 120 0 120{\\p0}
    """.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// RGB at a point given as fractions of the width and height.
private func rgb(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let w = Double(image.width), h = Double(image.height)
    ctx.draw(image, in: CGRect(x: -x * w, y: -(1 - y) * h, width: w, height: h))   // CG's origin is bottom-left
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}
private func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 170 && c.g < 90 && c.b < 90 }

/// The frame of an exported MP4 at `t` seconds into the clip.
private func frame(ofMP4 url: URL, at t: Double) throws -> CGImage {
    let jpeg = TestTemp.directory.appendingPathComponent("f-\(UUID().uuidString).jpg")
    let r = MPVFrameGrabber.grab(source: url.path, start: String(t), thumbnailTo: jpeg, width: nil)
    #expect(r.failure == nil, "\(r.failure ?? "")")
    let src = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
}

@Suite(.serialized) struct ClipSubtitleTests {
    // multi_audio_subs.mkv has a subtitle track of its own: the export must burn in
    // ours (the AI subtitles on screen), never the file's.
    private var source: URL { fixture("multi_audio_subs", "mkv") }

    @Test("CE7 an MP4 clip can carry the AI subtitles burned into the picture")
    func mp4WithSubtitles() async throws {
        let dir = try outDir()
        let plain = dir.appendingPathComponent("plain.mp4"), subbed = dir.appendingPathComponent("subbed.mp4")
        let range = ClipRange(start: 0.5, end: 2.5)
        _ = try await ClipExporter.export(source: source, range: range, format: .video, to: plain)
        _ = try await ClipExporter.export(source: source, range: range, format: .video,
                                          subtitles: try redBandSubtitles(), to: subbed)
        #expect(!isRed(rgb(try frame(ofMP4: plain, at: 1), x: 0.5, y: 0.85)), "no subtitles unless asked")
        #expect(isRed(rgb(try frame(ofMP4: subbed, at: 1), x: 0.5, y: 0.85)), "our subtitles are in the picture")
        #expect(!isRed(rgb(try frame(ofMP4: subbed, at: 1), x: 0.5, y: 0.3)), "…only where they belong")
    }

    @Test("CE8 a GIF can carry the AI subtitles too")
    func gifWithSubtitles() async throws {
        let dir = try outDir()
        let out = dir.appendingPathComponent("subbed.gif")
        _ = try await ClipExporter.export(source: source, range: ClipRange(start: 0.5, end: 1.5), format: .gif,
                                          subtitles: try redBandSubtitles(), to: out)
        let src = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let last = try #require(CGImageSourceCreateImageAtIndex(src, CGImageSourceGetCount(src) - 1, nil))
        #expect(isRed(rgb(first, x: 0.5, y: 0.85)) && isRed(rgb(last, x: 0.5, y: 0.85)))
        #expect(!isRed(rgb(first, x: 0.5, y: 0.3)))
    }

    @Test("CE9 export reports its progress, ending at 100%")
    func progress() async throws {
        let dir = try outDir()
        let seen = Locked<[Double]>([])
        _ = try await ClipExporter.export(source: fixture("testsrc-20s", "mp4"), range: ClipRange(start: 1, end: 5),
                                          format: .video, to: dir.appendingPathComponent("p.mp4"),
                                          progress: { f in seen.withLock { $0.append(f) } })
        let values = seen.withLock { $0 }
        #expect(values.count >= 2, "\(values)")
        #expect(values == values.sorted(), "never goes backwards: \(values)")
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
    }
}

/// A tiny lock-protected box for values written from export threads.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

@Suite(.serialized) @MainActor struct ClipSubtitlePlayerTests {
    @Test("CE10 the export offers the AI subtitles that are on screen, and nothing when none are")
    func offersShownSubtitles() async throws {
        let dir = try outDir()
        let video = dir.appendingPathComponent("talk.mp4")
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: video)
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.open(video)
        #expect(await waitUntil { w.loadedPath == video.path })
        #expect(w.clipSubtitleFile == nil, "no AI subtitles yet")

        let prefs = AISubtitlePreferences()
        prefs.source = "en-US"; prefs.target = nil
        let srt = SubtitleCache.url(forVideo: video.path, source: "en-US", target: nil)
        try FileManager.default.createDirectory(at: srt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "Hello.")]).write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }
        w.open(video)                                            // reopening loads the cached AI subtitles
        #expect(await waitUntil { w.clipSubtitleFile != nil })
        let file = try #require(w.clipSubtitleFile)
        #expect(file.pathExtension == "ass", "what is on screen: the styled version, band included")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite(.serialized) @MainActor struct ClipExportFlowTests {
    @Test("CE11 from the player: export with subtitles shows progress, then the result, and reveals the file")
    func flow() async throws {
        let dir = try outDir()
        let video = dir.appendingPathComponent("flow.mp4")
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: video)
        let w = PlayerWindowController()
        defer { w.shutdown() }
        var revealed: [URL] = []
        w.revealExported = { revealed = $0 }
        var huds: [String] = []
        w.open(video)
        #expect(await waitUntil { w.loadedPath == video.path })
        let out = dir.appendingPathComponent("flow clip.gif")
        w.runClipExport(source: video, range: ClipRange(start: 1, end: 2), format: .gif, subtitles: nil, to: out)
        let ok = await waitUntil(30) {
            if let t = w.playerView?.hud.text, huds.last != t { huds.append(t) }
            return !revealed.isEmpty
        }
        #expect(ok, "HUD: \(huds)")
        #expect(revealed == [out])
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(huds.contains { $0.hasPrefix(L("正在导出片段…")) })
        #expect(w.playerView?.hud.text == L("已导出：%@", out.lastPathComponent))
        try await Task.sleep(for: .milliseconds(300))           // no late progress update overwrites the result
        #expect(w.playerView?.hud.text == L("已导出：%@", out.lastPathComponent))
    }

    @Test("CE12 a failed export says why in the HUD and reveals nothing")
    func failure() async throws {
        let dir = try outDir()
        let video = dir.appendingPathComponent("v.mp4")
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: video)
        let bad = dir.appendingPathComponent("broken.mp4")
        try Data("nope".utf8).write(to: bad)
        let w = PlayerWindowController()
        defer { w.shutdown() }
        var revealed = false
        w.revealExported = { _ in revealed = true }
        w.open(video)
        #expect(await waitUntil { w.loadedPath == video.path })
        w.runClipExport(source: bad, range: ClipRange(start: 0, end: 1), format: .video, subtitles: nil,
                        to: dir.appendingPathComponent("x.mp4"))
        #expect(await waitUntil(20) { w.playerView?.hud.text.hasPrefix(L("导出失败：%@", "")) == true },
                "HUD: \(w.playerView?.hud.text ?? "")")
        #expect(!revealed)
    }
}
