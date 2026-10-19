import Foundation
import Testing
@testable import VideoTool

// AI subtitles (decision 2026-10-19: free, on-device). Recognition gives one
// segment per sentence with word timings; these rules turn that into readable cues
// and an .srt file the player loads.
struct SubtitleShapingTests {
    private func w(_ t: String, _ s: Double, _ e: Double) -> SpeechWord { SpeechWord(text: t, start: s, end: e) }

    @Test("SB1 a short sentence becomes one cue, trimmed, with the segment's times") func short() {
        let seg = SpeechSegment(text: "  Hello, everyone. ", start: 0, end: 1.2, words: [])
        #expect(CueShaper.cues(from: [seg]) == [SubtitleCue(start: 0, end: 1.2, text: "Hello, everyone.")])
    }

    @Test("SB2 empty and whitespace-only segments are dropped") func empty() {
        #expect(CueShaper.cues(from: [SpeechSegment(text: "   ", start: 0, end: 1, words: [])]).isEmpty)
    }

    @Test("SB3 a long sentence splits on word boundaries; every cue fits and keeps word times")
    func longWithWords() {
        let words = "This is a very long sentence that keeps going and going so that it no longer fits on a single subtitle line at all"
            .split(separator: " ").enumerated().map { i, t in w(String(t), Double(i) * 0.4, Double(i) * 0.4 + 0.35) }
        let seg = SpeechSegment(text: words.map(\.text).joined(separator: " "), start: 0, end: words.last!.end, words: words)
        let cues = CueShaper.cues(from: [seg])
        #expect(cues.count >= 2)
        #expect(cues.map(\.text).joined(separator: " ") == seg.text, "no word lost or duplicated")
        for c in cues {
            #expect(CueShaper.displayWidth(c.text) <= CueShaper.maxWidth)
            #expect(c.end - c.start <= CueShaper.maxDuration + 0.001)
        }
        #expect(cues.first?.start == 0)
        #expect(cues.last?.end == words.last!.end)
        for (a, b) in zip(cues, cues.dropFirst()) { #expect(a.end <= b.start) }
    }

    @Test("SB4 splits prefer the end of a clause (after , . ? !)") func clauseBoundary() {
        let text = "We went to the market early in the morning, and then we walked along the river until the sun went down."
        let words = text.split(separator: " ").enumerated().map { i, t in w(String(t), Double(i) * 0.3, Double(i) * 0.3 + 0.25) }
        let cues = CueShaper.cues(from: [SpeechSegment(text: text, start: 0, end: words.last!.end, words: words)])
        #expect(cues.first?.text.hasSuffix("morning,") == true)
    }

    @Test("SB5 without word timings a long sentence is split by length, times shared out by characters")
    func longWithoutWords() {
        let text = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let cues = CueShaper.cues(from: [SpeechSegment(text: text, start: 10, end: 30, words: [])])
        #expect(cues.count >= 2)
        #expect(cues.first?.start == 10 && cues.last?.end == 30)
        for c in cues { #expect(CueShaper.displayWidth(c.text) <= CueShaper.maxWidth) }
    }

    @Test("SB6 Chinese and Japanese characters count double for width; CJK text splits without spaces")
    func cjkWidth() {
        #expect(CueShaper.displayWidth("你好") == 4)
        #expect(CueShaper.displayWidth("ab") == 2)
        let text = String(repeating: "我们今天学习怎样更快地看视频，", count: 4)
        let cues = CueShaper.cues(from: [SpeechSegment(text: text, start: 0, end: 16, words: [])])
        #expect(cues.count >= 2)
        #expect(cues.map(\.text).joined() == text)
        for c in cues { #expect(CueShaper.displayWidth(c.text) <= CueShaper.maxWidth) }
    }

    @Test("SB7 cues never overlap or run backwards, and last at least a moment") func ordering() {
        let segs = [SpeechSegment(text: "One.", start: 1, end: 1.05, words: []),
                    SpeechSegment(text: "Two.", start: 1.0, end: 2, words: [])]
        let cues = CueShaper.cues(from: segs)
        #expect(cues.count == 2)
        #expect(cues[0].end - cues[0].start >= CueShaper.minDuration - 0.001 || cues[0].end <= cues[1].start)
        #expect(cues[0].end <= cues[1].start)
        #expect(cues.allSatisfy { $0.end > $0.start })
    }
}

struct SRTTests {
    @Test("SB8 timestamps are HH:MM:SS,mmm") func timestamps() {
        #expect(SRT.timestamp(0) == "00:00:00,000")
        #expect(SRT.timestamp(3725.5) == "01:02:05,500")
        #expect(SRT.timestamp(59.9996) == "00:01:00,000")
        #expect(SRT.timestamp(-3) == "00:00:00,000")
    }

    @Test("SB9 a bilingual file puts the translation above the original, numbered from 1")
    func bilingual() {
        let cues = [SubtitleCue(start: 0, end: 1.2, text: "Hello, everyone.", translation: "大家好。"),
                    SubtitleCue(start: 1.32, end: 5.04, text: "Today we will learn.", translation: nil)]
        #expect(SRT.document(cues) == """
            1
            00:00:00,000 --> 00:00:01,200
            大家好。
            Hello, everyone.

            2
            00:00:01,320 --> 00:00:05,040
            Today we will learn.

            """)
    }

    @Test("SB10 blank lines inside a cue cannot break the file") func noBlankLines() {
        let doc = SRT.document([SubtitleCue(start: 0, end: 1, text: "a\n\nb", translation: " \n")])
        #expect(!doc.contains("\n\n\n"))
        #expect(doc.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == 1)
    }
}
