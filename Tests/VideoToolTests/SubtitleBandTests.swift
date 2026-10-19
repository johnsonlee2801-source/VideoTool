import AppKit
import Testing
@testable import VideoTool

// Band behind AI subtitles (user, 2026-10-19): many videos already have subtitles
// burnt into the picture; a semi-transparent dark band over the bottom of the
// picture hides them so the AI subtitles stand out. Drawn by the player as part of
// the subtitle file, so it fits the picture and goes away with the subtitles.

struct SubtitleBandFormatTests {
    private let cues = [SubtitleCue(start: 1, end: 2.5, text: "Hello {there}", translation: "你好"),
                        SubtitleCue(start: 3, end: 4, text: "Line one\nline two")]

    @Test("BA1 an ASS file: a band over the bottom of the picture for the whole video, then the lines above it")
    func withBand() {
        let doc = ASS.document(cues, band: true, until: 1500)
        #expect(doc.contains("PlayResX: 1920") && doc.contains("PlayResY: 1080"))
        let band = doc.split(separator: "\n").filter { $0.hasPrefix("Dialogue: 0,") }
        #expect(band.count == 1)
        #expect(band[0].contains("0:00:00.00,0:25:00.00") && band[0].contains("\\p1"), "covers the whole video")
        #expect(band[0].contains("\\1a&H\(String(format: "%02X", ASS.bandAlpha))&"), "semi-transparent")
        let lines = doc.split(separator: "\n").filter { $0.hasPrefix("Dialogue: 1,") }
        #expect(lines.count == 2)
        #expect(lines[0].contains("0:00:01.00,0:00:02.50"))
        #expect(lines[0].range(of: "你好")!.lowerBound < lines[0].range(of: "Hello")!.lowerBound, "translation above the original")
        #expect(!lines[0].contains("{there}"), "braces in text cannot become style codes")
        #expect(lines[1].contains("Line one\\Nline two"))
    }

    @Test("BA2 without the band (switched off) only the lines are drawn") func withoutBand() {
        let doc = ASS.document(cues, band: false, until: 1500)
        #expect(!doc.contains("Dialogue: 0,"))
        #expect(doc.split(separator: "\n").filter { $0.hasPrefix("Dialogue: 1,") }.count == 2)
    }

    @Test("BA3 bilingual subtitle files read back as translation + original") func bilingualParse() {
        let srt = SRT.document([SubtitleCue(start: 0, end: 1, text: "Hello.", translation: "你好。")])
        #expect(SRT.parse(srt, bilingual: true) == [SubtitleCue(start: 0, end: 1, text: "Hello.", translation: "你好。")])
        #expect(SRT.parse(srt).first?.text == "你好。\nHello.")
    }

    @Test("BA4 the band is on unless switched off, and remembered") func preference() throws {
        let suite = "videotool-tests-ba4-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(AISubtitlePreferences(defaults: d).band)
        AISubtitlePreferences(defaults: d).band = false
        #expect(!AISubtitlePreferences(defaults: d).band)
    }
}

@Suite(.serialized) struct SubtitleBandRenderTests {
    /// A light picture with dark "burnt-in" subtitles at the bottom, like many downloads.
    private func burntInPicture() throws -> URL {
        let url = TestTemp.directory.appendingPathComponent("burnt-\(UUID().uuidString).jpg")
        let image = NSImage(size: NSSize(width: 1920, height: 1080), flipped: false) { r in
            NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.75, alpha: 1).setFill(); r.fill()    // a sky-ish scene
            // Burnt-in subtitles as they usually look: white with a black outline.
            let font = NSFont.systemFont(ofSize: 64, weight: .bold)
            let line = "这是视频里原本就有的字幕 Burnt-in subtitles"
            let outline = NSAttributedString(string: line, attributes: [.font: font, .strokeColor: NSColor.black, .strokeWidth: 10])
            let fill = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.white])
            let at = NSPoint(x: (r.width - fill.size().width) / 2, y: 70)
            outline.draw(at: at); fill.draw(at: at)
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])).write(to: url)   // the bundled FFmpeg decodes JPEG, not PNG
        return url
    }

    /// Average brightness (0…1) of a horizontal strip of a JPEG, top = 0.
    private func brightness(_ jpeg: URL, from top: Double, to bottom: Double) throws -> Double {
        let data = try Data(contentsOf: jpeg)
        let rep = try #require(NSBitmapImageRep(data: data))
        var sum = 0.0, n = 0
        for y in Int(top * Double(rep.pixelsHigh))..<Int(bottom * Double(rep.pixelsHigh)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) { sum += c.brightnessComponent; n += 1 }
            }
        }
        return sum / Double(max(n, 1))
    }

    @Test("BA5 rendered by the real player: the band darkens the bottom (hiding burnt-in text), the rest is untouched")
    func rendered() throws {
        let picture = try burntInPicture()
        let cues = [SubtitleCue(start: 0, end: 60, text: "Press and hold the picture to speed up.", translation: "按住画面，就能加速播放。")]
        func render(band: Bool) throws -> URL {
            let ass = TestTemp.directory.appendingPathComponent("band-\(band)-\(UUID().uuidString).ass")
            try ASS.document(cues, band: band, until: 60).write(to: ass, atomically: true, encoding: .utf8)
            let out = TestTemp.directory.appendingPathComponent("band-\(band).jpg")
            let r = MPVFrameGrabber.grab(source: picture.path, start: "0", thumbnailTo: out, subtitles: ass.path)
            #expect(r.failure == nil, "\(r.failure ?? "")")
            return out
        }
        let on = try render(band: true), off = try render(band: false)
        let bottomOn = try brightness(on, from: 0.8, to: 0.98), bottomOff = try brightness(off, from: 0.8, to: 0.98)
        let topOn = try brightness(on, from: 0.05, to: 0.5), topOff = try brightness(off, from: 0.05, to: 0.5)
        #expect(bottomOn < bottomOff * 0.5, "band: bottom \(bottomOn) vs \(bottomOff) without")
        #expect(abs(topOn - topOff) < 0.02, "the picture above the band is untouched: \(topOn) vs \(topOff)")
        for (src, name) in [(on, "videotool-tests-band-on.jpg"), (off, "videotool-tests-band-off.jpg")] {   // for a look by eye
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }
}
