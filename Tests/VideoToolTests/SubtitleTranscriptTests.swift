import Foundation
import Testing
@testable import VideoTool

@Suite struct SubtitleTranscriptTests {
    @Test("ST1 search covers original and translated text, including wrapped Chinese")
    func search() {
        let document = SubtitleTranscript(cues: [SubtitleCue(start: 1, end: 3, text: "Hello world", translation: "你好\n世界"), SubtitleCue(start: 5, end: 8, text: "Second sentence")])
        #expect(document.matches("HELLO") == [0])
        #expect(document.matches("你好世界") == [0])
        #expect(document.matches("sentence") == [1])
        #expect(document.replayIndex(at: 6) == 1)
        #expect(document.replayIndex(at: 5.1) == 0)
        #expect(document.replayIndex(at: 0) == nil)
    }
    @Test("ST2 website JSON3 and VTT become timed plain-text cues")
    func formats() throws {
        let json = Data(#"{"events":[{"tStartMs":1000,"dDurationMs":2000,"segs":[{"utf8":"hello "},{"utf8":"world"}]}]}"#.utf8)
        let document = try SubtitleTranscript.decode(json, format: "json3")
        #expect(document.cues == [SubtitleCue(start: 1, end: 3, text: "hello world")])
        let vtt = Data("WEBVTT\n\n00:01.000 --> 00:03.000 align:start\n<c>hello &amp; world</c>\n\n".utf8)
        #expect(try SubtitleTranscript.decode(vtt, format: "vtt").cues.first?.text == "hello & world")
    }
    @Test("ST3 invalid cue times and duplicate events do not enter searchable results")
    func invalidCues() {
        let cue = SubtitleCue(start: 1, end: 3, text: "one")
        let document = SubtitleTranscript(cues: [cue, cue, SubtitleCue(start: .nan, end: 3, text: "bad"), SubtitleCue(start: 5, end: 4, text: "reversed")])
        #expect(document.cues == [cue])
    }
}
