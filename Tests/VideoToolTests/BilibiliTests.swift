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

@Suite struct BilibiliMuxedTests {
    @Test("BL4 a muxed stream whose codecs yt-dlp left unknown still plays; only an explicit none means no track")
    func unknownCodecs() throws {
        let request = try NetworkVideo("https://www.bilibili.com/video/BV1bK411W797")
        let muxed = #"{"id":"BV1bK411W797","title":"Legacy","duration":90,"url":"https://upos-sz-mirrorcos.bilivideo.com/legacy.mp4"}"#
        let media = try ResolvedNetworkVideo.decode(data: Data(muxed.utf8), request: request)
        #expect(media.videoURL.lastPathComponent == "legacy.mp4" && media.audioURL == nil)
        let nullCodecs = muxed.replacingOccurrences(of: #""duration":90"#, with: #""duration":90,"vcodec":null,"acodec":null"#)
        #expect(try ResolvedNetworkVideo.decode(data: Data(nullCodecs.utf8), request: request).audioURL == nil)
        for explicit in [#""vcodec":"none""#, #""acodec":"none""#] {
            let bad = muxed.replacingOccurrences(of: #""duration":90"#, with: #""duration":90,"# + explicit)
            #expect(throws: NetworkVideoFailure.invalidResponse) { try ResolvedNetworkVideo.decode(data: Data(bad.utf8), request: request) }
        }
    }
}

@Suite struct BilibiliCatalogTests {
    @Test("BC3 an AV link with leading zeros matches the numeric aid of its catalog")
    func leadingZeroAid() throws {
        let data = Data(#"{"code":0,"data":{"bvid":"BV1bK411W797","aid":498159642,"pages":[{"page":1,"part":"one"}]}}"#.utf8)
        let value = try BilibiliCatalog.decode(data, request: NetworkVideo("https://bilibili.com/video/av0498159642"))
        #expect(value.request.key == "bilibili:BV1bK411W797:p1")
        #expect(throws: Error.self) { try BilibiliCatalog.decode(data, request: NetworkVideo("https://bilibili.com/video/av4981596420")) }
    }

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

@Suite @MainActor struct BilibiliTransferTests {
    private let api = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=BV1bK411W797")!
    private let short = URL(string: "https://b23.tv/Ab123xy")!
    private func redirect(_ transfer: BilibiliTransfer, from: URL, to: String, session: URLSession) -> Bool {
        var allowed = false
        let response = HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: nil)!
        transfer.urlSession(session, task: session.dataTask(with: from), willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: to)!)) { allowed = $0 != nil }
        return allowed
    }
    @Test("BT1 short links follow only bounded HTTPS b23.tv hops and stop at the first Bilibili video")
    func shortLinkRedirects() {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        var results: [Result<(Data, URL), NetworkVideoFailure>] = []
        let video = BilibiliTransfer(url: short, shortLink: true) { results.append($0) }
        #expect(redirect(video, from: short, to: "https://b23.tv/Next12", session: session))
        #expect(!redirect(video, from: short, to: "https://www.bilibili.com/video/BV1bK411W797?p=2", session: session))
        if case .success(let pair) = results.last { #expect(pair.0.isEmpty && pair.1.absoluteString.hasSuffix("BV1bK411W797?p=2")) } else { Issue.record("expected the video URL") }
        for target in ["https://evil.test/video", "http://b23.tv/x", "https://user@b23.tv/x", "https://b23.tv:8443/x"] {
            let transfer = BilibiliTransfer(url: short, shortLink: true) { results.append($0) }
            #expect(!redirect(transfer, from: short, to: target, session: session))
            if case .failure(let error) = results.last { #expect(error == .invalidLink) } else { Issue.record("expected invalidLink for \(target)") }
        }
        let looping = BilibiliTransfer(url: short, shortLink: true) { results.append($0) }
        for hop in 1...5 { #expect(redirect(looping, from: short, to: "https://b23.tv/Hop\(hop)", session: session)) }
        #expect(!redirect(looping, from: short, to: "https://b23.tv/Hop6", session: session))
        let api = BilibiliTransfer(url: api, shortLink: false) { results.append($0) }
        #expect(!redirect(api, from: self.api, to: "https://api.bilibili.com/elsewhere", session: session))
        if case .failure(let error) = results.last { #expect(error == .invalidLink) } else { Issue.record("API redirects must fail") }
    }
    @Test("BT2 catalog responses are bounded, classified once, and cancellation discards delivery")
    func responses() throws {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: api)
        var results: [Result<(Data, URL), NetworkVideoFailure>] = []
        let ok = BilibiliTransfer(url: api, shortLink: false) { results.append($0) }
        var disposition: URLSession.ResponseDisposition?
        ok.urlSession(session, dataTask: task, didReceive: try #require(HTTPURLResponse(url: api, statusCode: 200, httpVersion: nil, headerFields: nil))) { disposition = $0 }
        #expect(disposition == .allow)
        ok.urlSession(session, dataTask: task, didReceive: Data("{}".utf8))
        ok.urlSession(session, task: task, didCompleteWithError: nil)
        if case .success(let pair) = results.last { #expect(pair.0 == Data("{}".utf8) && pair.1 == api) } else { Issue.record("expected data") }
        let denied = BilibiliTransfer(url: api, shortLink: false) { results.append($0) }
        denied.urlSession(session, dataTask: task, didReceive: try #require(HTTPURLResponse(url: api, statusCode: 404, httpVersion: nil, headerFields: nil))) { disposition = $0 }
        #expect(disposition == .cancel)
        if case .failure(let error) = results.last { #expect(error == .restricted) } else { Issue.record("expected restricted") }
        let huge = BilibiliTransfer(url: api, shortLink: false) { results.append($0) }
        huge.urlSession(session, dataTask: task, didReceive: Data(count: 1024 * 1024 + 1))
        if case .failure(let error) = results.last { #expect(error == .invalidResponse) } else { Issue.record("expected invalidResponse") }
        let count = results.count
        huge.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(results.count == count)
        for (error, expected) in [(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), NetworkVideoFailure.timeout), (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .network)] {
            let failing = BilibiliTransfer(url: api, shortLink: false) { results.append($0) }
            failing.urlSession(session, task: task, didCompleteWithError: error)
            if case .failure(let value) = results.last { #expect(value == expected) } else { Issue.record("expected \(expected)") }
        }
        let cancelled = BilibiliTransfer(url: api, shortLink: false) { results.append($0) }
        let before = results.count
        cancelled.cancel(); cancelled.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(results.count == before)
    }
}
