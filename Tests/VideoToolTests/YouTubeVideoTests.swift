import Foundation
import Testing
@testable import VideoTool

@Suite struct YouTubeVideoTests {
    @Test("YT1 link variants share one identity, ignore playlists and keep explicit time")
    func canonicalLinks() throws {
        let id = "BaW_jenozKc"
        for url in ["https://www.youtube.com/watch?v=\(id)&list=PL123&t=1m2s", "https://youtu.be/\(id)?t=62", "https://m.youtube.com/shorts/\(id)?start=62", "https://www.youtube.com/embed/\(id)#t=62"] {
            let video = try NetworkVideo(url)
            #expect(video.id == id && video.key == "youtube:\(id)")
            #expect(video.url.absoluteString == "https://www.youtube.com/watch?v=\(id)")
            #expect(video.start == 62)
        }
        #expect(try NetworkVideo("  https://youtu.be/\(id) \n").start == nil)
        #expect(try NetworkVideo("https://youtu.be/\(id)?t=0").start == 0)
    }

    @Test("YT2 reject lookalikes, authentication, non-web URLs and invalid IDs")
    func invalidLinks() {
        for url in ["file:///tmp/film", "--exec=bad", "https://youtube.com.evil.test/watch?v=BaW_jenozKc", "https://evil.test/youtube.com/BaW_jenozKc", "https://user:pass@youtube.com/watch?v=BaW_jenozKc", "https://youtube.com:123/watch?v=BaW_jenozKc", "https://youtube.com/playlist?list=123", "https://youtu.be/short", "https://youtu.be/BaW_jenozKc/extra", "https://youtube.com/watch?v=BaW_jenozKc&v=xxxxxxxxxxx"] {
            #expect(throws: Error.self) { try NetworkVideo(url) }
        }
    }

    @Test("YT3 invalid time cannot overflow or select a different video")
    func timeValidation() throws {
        for t in ["-1", "nan", "9999999999999999999999", "1x", "1m2sxyz"] {
            #expect(try NetworkVideo("https://youtu.be/BaW_jenozKc?t=\(t)").start == nil)
        }
    }

    @Test("YT4 decode separated streams with stable identity and safe headers")
    func separateStreams() throws {
        let request = try NetworkVideo("https://youtu.be/BaW_jenozKc")
        let data = Data(#"{"id":"BaW_jenozKc","title":"Test, 日本語","duration":30,"requested_formats":[{"url":"https://r1.googlevideo.com/v?x=1,2","vcodec":"avc1","acodec":"none","http_headers":{"User-Agent":"agent","Referer":"https://www.youtube.com/"}},{"url":"https://r2.googlevideo.com/a","vcodec":"none","acodec":"opus"}]}"#.utf8)
        let media = try ResolvedNetworkVideo.decode(data: data, request: request)
        #expect(media.videoURL.host == "r1.googlevideo.com")
        #expect(media.audioURL?.host == "r2.googlevideo.com")
        #expect(media.title == "Test, 日本語" && media.request.key == request.key)
        #expect(media.headers["User-Agent"] == "agent")
    }

    @Test("YT5 malformed, mismatched, live or unsafe extractor output never reaches mpv")
    func rejectOutput() throws {
        let request = try NetworkVideo("https://youtu.be/BaW_jenozKc")
        for json in ["{}", #"{"id":"other","url":"https://r.googlevideo.com/v"}"#, #"{"id":"BaW_jenozKc","is_live":true,"url":"https://r.googlevideo.com/v"}"#, #"{"id":"BaW_jenozKc","url":"file:///tmp/private"}"#, #"{"id":"BaW_jenozKc","url":"https://googlevideo.com.evil.test/v"}"#, #"{"id":"BaW_jenozKc","url":"https://r.googlevideo.com/v","http_headers":{"User-Agent":"x\r\nInjected: yes"}}"#] {
            #expect(throws: Error.self) { try ResolvedNetworkVideo.decode(data: Data(json.utf8), request: request) }
        }
    }

    @Test("YT6 control characters and differing stream headers cannot corrupt mpv options")
    func controlCharacters() throws {
        let request = try NetworkVideo("https://youtu.be/BaW_jenozKc")
        let json = #"{"id":"BaW_jenozKc","duration":30,"title":"A\u0000,title=bad","vcodec":"avc1","acodec":"aac","url":"https://r.googlevideo.com/v","http_headers":{"User-Agent":"x\u0000suffix"}}"#
        #expect(throws: Error.self) { try ResolvedNetworkVideo.decode(data: Data(json.utf8), request: request) }
    }
}
