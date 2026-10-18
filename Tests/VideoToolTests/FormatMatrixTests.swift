import AppKit
import Testing
@testable import VideoTool

// "Opens every video": each fixture in Tests/Fixtures/formats (made by
// tools/make_format_fixtures.sh) must be probed correctly, give a thumbnail when
// it has a picture, and actually play in the real engine. Runs in the
// integration lane (real libmpv).

private final class Marker {}
private func fixture(_ name: String) -> String? {
    let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
    return Bundle(for: Marker.self).path(forResource: base, ofType: ext)
}

struct FormatCase: CustomStringConvertible, Sendable {
    var file: String
    var width: Int          // displayed size (rotation applied); 0 for audio-only
    var height: Int
    var duration: Double = 3
    var audio = 1
    var subtitles = 0
    var description: String { file }
}

private let videoCases: [FormatCase] = [
    .init(file: "h264_aac.mp4", width: 320, height: 180),
    .init(file: "hevc_aac.mp4", width: 320, height: 180),
    .init(file: "hevc_10bit.mkv", width: 320, height: 180),
    .init(file: "vp9_opus.webm", width: 320, height: 180),
    .init(file: "vp8_opus.webm", width: 320, height: 180),
    .init(file: "av1_opus.mkv", width: 320, height: 180),
    .init(file: "mpeg4_mp3.avi", width: 320, height: 180),
    .init(file: "mpeg2_ac3.ts", width: 320, height: 180),
    .init(file: "mpeg2_mp2.mpg", width: 320, height: 180),
    .init(file: "prores_pcm.mov", width: 320, height: 180),
    .init(file: "h264_aac.flv", width: 320, height: 180),
    .init(file: "wmv2_mp3.wmv", width: 320, height: 180),
    .init(file: "h263_aac.3gp", width: 176, height: 144),
    .init(file: "mjpeg_pcm.avi", width: 320, height: 180),
    .init(file: "vertical_9x16.mp4", width: 180, height: 320),
    .init(file: "hfr_60fps.mp4", width: 320, height: 180),
    .init(file: "rotated_90.mp4", width: 180, height: 320),
    .init(file: "multi_audio_subs.mkv", width: 320, height: 180, audio: 2, subtitles: 1),
    .init(file: "测试 视频 #1 (中文)&'名字.mkv", width: 320, height: 180),
]

@MainActor
private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite(.serialized) @MainActor struct FormatMatrixTests {
    @Test("FM1 every video format is probed with the right duration and displayed size", arguments: videoCases)
    func probe(_ c: FormatCase) throws {
        let path = try #require(fixture(c.file), "fixture missing from test bundle: \(c.file)")
        let thumb = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString).jpg")
        let p = try #require(MPVMediaProber().probe(source: path, thumbnailTo: thumb), "\(MPVThumbnailMaker.lastFailure ?? "")")
        #expect(abs(p.duration - c.duration) < 0.25, "duration \(p.duration)")
        #expect(p.width == c.width && p.height == c.height, "size \(p.width)x\(p.height)")
        let data = try Data(contentsOf: thumb)
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF], "thumbnail is a JPEG")
        let image = try #require(NSImage(contentsOf: thumb))
        #expect((image.size.width > image.size.height) == (c.width > c.height), "thumbnail orientation matches the video")
    }

    @Test("FM2 every video format really plays in the player engine, with all its tracks", arguments: videoCases)
    func plays(_ c: FormatCase) async throws {
        let path = try #require(fixture(c.file))
        let session = try PlaybackSession()
        defer { session.shutdown() }
        let engine = session.engine
        var loaded = false, errors: [String] = []
        engine.onEvent = { e in
            if case .fileLoaded = e { loaded = true }
            if case .log(let l) = e, l.contains("error") { errors.append(l) }
        }
        engine.loadTarget(path)
        #expect(await waitUntil { loaded }, "never loaded: \(errors)")
        engine.setPaused(false)
        #expect(await waitUntil { engine.state.timePos > 0.5 }, "did not advance: \(engine.state) \(errors)")
        let tracks = engine.trackCounts()
        #expect(tracks.video == 1 && tracks.audio == c.audio && tracks.subtitle == c.subtitles, "tracks \(tracks)")
    }

    @Test("FM3 audio-only files: duration read, no picture, thumbnail fails cleanly", arguments: ["audio_only.mp3", "audio_only.flac"])
    func audioOnly(_ name: String) throws {
        let path = try #require(fixture(name))
        let thumb = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString).jpg")
        let p = try #require(MPVMediaProber().probe(source: path, thumbnailTo: thumb))
        #expect(abs(p.duration - 3) < 0.25)
        #expect(p.width == 0 && p.height == 0)
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
    }

    @Test("FM4 a file cut off mid-download never hangs: probe and playback finish within the time limit")
    func truncated() async throws {
        let path = try #require(fixture("truncated.mp4"))
        let start = Date()
        _ = MPVMediaProber().probe(source: path, thumbnailTo: FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString).jpg"))
        #expect(Date().timeIntervalSince(start) < MPVFrameGrabber.timeout + 1)

        let session = try PlaybackSession()
        defer { session.shutdown() }
        var settled = false
        session.engine.onEvent = { e in
            switch e { case .fileLoaded, .endFile: settled = true; default: break }
        }
        session.engine.loadTarget(path)
        #expect(await waitUntil(8) { settled }, "neither loaded nor failed")
    }

    @Test("FM5 every fixture's extension is one the app claims to open") func extensionsClaimed() {
        for c in videoCases { #expect(MediaTypes.isMedia(URL(fileURLWithPath: c.file)), "\(c.file)") }
        #expect(MediaTypes.isMedia(URL(fileURLWithPath: "a.mp3")) && MediaTypes.isMedia(URL(fileURLWithPath: "a.flac")))
    }

    @Test("FM6 bitmap rotation: 90° clockwise swaps the size and moves the top-left pixel to the top-right")
    func rotation() throws {
        // 2x1 image: left pixel red, right pixel blue
        let ctx = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let img = try #require(ctx.makeImage())
        let r = try #require(MPVFrameGrabber.rotated(img, clockwise: 90))
        #expect(r.width == 1 && r.height == 2)
        let rep = NSBitmapImageRep(cgImage: r)
        #expect(rep.colorAt(x: 0, y: 0)?.redComponent ?? 0 > 0.9, "after a clockwise turn the left (red) pixel is on top")
        #expect(MPVFrameGrabber.rotated(img, clockwise: 0).map { $0.width } == 2)
        #expect(MPVFrameGrabber.rotated(img, clockwise: 180).map { $0.width } == 2)
    }

    @Test("FM7 a rotated phone video gives a portrait thumbnail without crashing the process")
    func rotatedThumbnail() throws {
        let path = try #require(fixture("rotated_90.mp4"))
        let thumb = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString).jpg")
        let p = try #require(MPVMediaProber().probe(source: path, thumbnailTo: thumb))
        #expect(p.width == 180 && p.height == 320)
        let image = try #require(NSImage(contentsOf: thumb))
        #expect(image.size.height > image.size.width)
    }
}
