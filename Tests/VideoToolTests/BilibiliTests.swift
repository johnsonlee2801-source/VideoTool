import Foundation
import Testing
@testable import VideoTool

@Suite struct BilibiliTests {
    @Test("BL1 Bilibili URLs normalize tracking, retain page and isolate identities")
    func links() throws {
        let first = try NetworkVideo("https://www.bilibili.com/video/BV1bK411W797/?spm_id_from=tracking")
        let second = try NetworkVideo("https://m.bilibili.com/video/BV1bK411W797?p=2&t=12")
        #expect(first.url.absoluteString == "https://www.bilibili.com/video/BV1bK411W797?p=1")
        #expect(second.url.absoluteString == "https://www.bilibili.com/video/BV1bK411W797?p=2")
        #expect(first.key == "bilibili:BV1bK411W797:p1")
        #expect(second.key == "bilibili:BV1bK411W797:p2" && second.start == 12)
    }
    @Test("BL2 accept bounded short links, reject lookalikes, invalid pages and credentials")
    func shortLinks() throws {
        #expect(try NetworkVideo("https://b23.tv/Ab123xy").url.absoluteString == "https://b23.tv/Ab123xy")
        for url in ["https://b23.tv.evil.test/abc", "https://user:pw@b23.tv/abc", "https://b23.tv/abc/extra", "https://bilibili.com/video/BV1bK411W797?p=0", "https://bilibili.com/video/BV1bK411W797?p=2&p=3", "https://bilibili.com/video/BV1bK411W797?p=999999999", "https://bilibili.com/bangumi/play/ep123"] {
            #expect(throws: Error.self) { try NetworkVideo(url) }
        }
    }
    @Test("BL3 separated Bilibili streams validate matching part and CDN")
    func streams() throws {
        let request = try NetworkVideo("https://www.bilibili.com/video/BV1bK411W797?p=2")
        let json = #"{"id":"BV1bK411W797_p2","title":"Part 2","duration":90,"requested_formats":[{"url":"https://upos-sz-mirrorcos.bilivideo.com/v","vcodec":"avc1","acodec":"none"},{"url":"https://upos-sz-mirrorcos.bilivideo.com/a","vcodec":"none","acodec":"aac"}],"http_headers":{"Referer":"https://www.bilibili.com/video/BV1bK411W797?p=2"}}"#
        let media = try ResolvedNetworkVideo.decode(data: Data(json.utf8), request: request)
        #expect(media.audioURL != nil && media.request.key == "bilibili:BV1bK411W797:p2")
        for bad in [json.replacingOccurrences(of: "_p2", with: "_p1"), json.replacingOccurrences(of: "bilivideo.com", with: "bilivideo.com.evil.test"), json.replacingOccurrences(of: "https://upos", with: "file://upos")] {
            #expect(throws: Error.self) { try ResolvedNetworkVideo.decode(data: Data(bad.utf8), request: request) }
        }
    }
}

@Suite struct BilibiliCatalogTests {
    @Test("BC2 API errors, paid previews and malformed page catalogs are rejected")
    func invalidCatalogs() throws {
        let request = try NetworkVideo("https://bilibili.com/video/BV1bK411W797")
        for json in [#"{"code":-101}"#, #"{"code":0,"data":{"bvid":"BV1bK411W797","rights":{"pay":1},"pages":[{"page":1,"part":"preview"}]}}"#, #"{"code":0,"data":{"bvid":"BV1bK411W797","pages":[{"page":2,"part":"wrong order"}]}}"#, #"{"code":0,"data":{"bvid":"BV1bK411W797","pages":[]}}"#] {
            #expect(throws: Error.self) { try BilibiliCatalog.decode(Data(json.utf8), request: request) }
        }
    }

    @Test("BC1 AV and BV normalize to the same stable identity; pages are ordered and bounded")
    func catalog() throws {
        let data = Data(#"{"code":0,"data":{"bvid":"BV1bK411W797","aid":498159642,"pages":[{"page":1,"part":"one"},{"page":2,"part":"two"}]}}"#.utf8)
        let value = try BilibiliCatalog.decode(data, request: NetworkVideo("https://bilibili.com/video/av498159642?p=2&t=12"))
        #expect(value.request.key == "bilibili:BV1bK411W797:p2" && value.request.start == 12)
        #expect(value.parts == [BilibiliPart(page: 1, title: "one"), BilibiliPart(page: 2, title: "two")])
        for url in ["https://bilibili.com/video/BV13x41117TL", "https://bilibili.com/video/BV1bK411W797?p=3", "https://bilibili.com/video/av123"] {
            #expect(throws: Error.self) { try BilibiliCatalog.decode(data, request: NetworkVideo(url)) }
        }
    }
}


@Suite @MainActor struct BilibiliPersistenceTests {
    @Test("BP1 each BV page has independent persistent stars and resume; AV is normalized before use")
    func identities() throws {
        let name = "videotool-tests-bili-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let resumes = ResumePositionStore(defaults: defaults)
        let first = try NetworkVideo("https://bilibili.com/video/BV1bK411W797?p=1")
        let second = try first.selecting(page: 2)
        resumes.save(31, for: first.url); resumes.save(42, for: second.url)
        #expect(resumes.position(for: first.url) == 31 && resumes.position(for: second.url) == 42)
        let store = try BookmarkStore(path: TestTemp.directory.appendingPathComponent("bili-" + UUID().uuidString + ".sqlite").path)
        let engine = FakeEngine(), thumbs = FakeThumbnailMaker()
        let controller = BookmarkController(store: store, engine: engine, thumbnails: thumbs)
        controller.openNetwork(first); engine.state.timePos = 8; _ = controller.toggleAtCurrentTime()
        controller.openNetwork(second)
        #expect(controller.bookmarks.isEmpty)
        engine.state.timePos = 16; _ = controller.toggleAtCurrentTime()
        controller.openNetwork(first)
        #expect(controller.bookmarks.map(\.time) == [8] && thumbs.requests.isEmpty)
        engine.state.timePos = 0
        controller.jumpToNext()
        #expect(engine.seeks.last == 6)
        controller.fileClosed()
    }
}
