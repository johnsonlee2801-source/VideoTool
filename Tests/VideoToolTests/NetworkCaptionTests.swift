import Foundation
import Testing
@testable import VideoTool

@Suite struct NetworkCaptionTests {
    @Test("SC1 only safe website caption endpoints become selectable sources")
    func endpointPolicy() throws {
        let video = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        let data = Data(#"{"id":"M7lc1UVf-VE","duration":30,"vcodec":"avc1","acodec":"aac","url":"https://r.googlevideo.com/v","requested_subtitles":{"en":{"ext":"json3","url":"https://www.youtube.com/api/timedtext?v=M7lc1UVf-VE"},"bad":{"ext":"vtt","url":"https://youtube.com.evil.test/api/timedtext"},"local":{"ext":"srt","url":"file:///tmp/example.srt"}}}"#.utf8)
        let sources = try NetworkCaptionTrack.decode(data, video: video)
        #expect(sources.map(\.id) == ["en"])
        #expect(!NetworkCaptionTrack.allows(URL(string: "https://www.youtube.com/redirect?url=http://localhost")!, site: .youtube))
        #expect(!NetworkCaptionTrack.allows(URL(string: "http://www.youtube.com/api/timedtext")!, site: .youtube))
    }
    @Test("SC5 real-world catalogs with 313 language variants remain readable within the bounded response")
    func manyLanguages() throws {
        let video = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        var rows: [String: Any] = [:]
        for index in 0..<313 { rows["language-\(index)"] = ["ext": "json3", "url": "https://www.youtube.com/api/timedtext?v=M7lc1UVf-VE"] }
        let root: [String: Any] = ["id": video.id, "duration": 30, "vcodec": "avc1", "acodec": "aac", "url": "https://r.googlevideo.com/v", "requested_subtitles": rows]
        let result = try NetworkCaptionTrack.decode(JSONSerialization.data(withJSONObject: root), video: video)
        #expect(result.count == 313)
    }
    @Test("SC6 original subtitles are preferred to translated website variants")
    func originalFirst() throws {
        let video = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        let data = Data(#"{"id":"M7lc1UVf-VE","duration":30,"vcodec":"avc1","acodec":"aac","url":"https://r.googlevideo.com/v","requested_subtitles":{"en":{"ext":"json3","url":"https://www.youtube.com/api/timedtext?lang=en"},"zh-Hans":{"ext":"json3","url":"https://www.youtube.com/api/timedtext?lang=en&tlang=zh-Hans"}}}"#.utf8)
        #expect(try NetworkCaptionTrack.decode(data, video: video).first?.id == "en")
    }
    @Test("SC7 Bilibili inline text captions work without downloading danmaku")
    func inlineBilibili() throws {
        let video = try NetworkVideo("https://www.bilibili.com/video/BV1bK411W797")
        let root: [String: Any] = ["id": "BV1bK411W797_p1", "duration": 30, "vcodec": "avc1", "acodec": "aac", "url": "https://x.bilivideo.com/video", "requested_subtitles": ["zh-Hans": ["ext": "srt", "data": "1\n00:00:01,000 --> 00:00:03,000\n公开字幕\n"], "danmaku": ["ext": "xml", "data": "ignored"]]]
        let tracks = try NetworkCaptionTrack.decode(JSONSerialization.data(withJSONObject: root), video: video)
        #expect(tracks.count == 1 && tracks.first?.url == nil)
        let text = try #require(tracks.first?.inline)
        #expect(try SubtitleTranscript.decode(Data(text.utf8), format: "srt").cues.first?.text == "公开字幕")
    }
    @Test("SC2 caption metadata invocation is simulated and isolated, with no subtitle files written")
    func arguments() throws {
        let args = NetworkCaptionCatalog.arguments(for: try NetworkVideo("https://youtu.be/M7lc1UVf-VE"), deno: "/tools/deno")
        for flag in ["--simulate", "--write-subs", "--write-auto-subs", "--ignore-config", "--no-cache-dir", "--no-plugin-dirs", "--no-remote-components"] { #expect(args.contains(flag)) }
        #expect(Array(args.suffix(2)) == ["--", "https://www.youtube.com/watch?v=M7lc1UVf-VE"])
        #expect(!args.contains(where: { $0.contains("cookies") || $0 == "--no-simulate" }))
    }
}
