import AppKit
import Testing
@testable import VideoTool

/// Anonymous public access only; independent from deterministic offline gates.
@Suite(.serialized) @MainActor struct BilibiliLiveTests {
    @Test("BLL1 public multi-part video actually resolves and decodes audio/video",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOTOOL_BILIBILI_LIVE"] == "1"))
    func playback() async throws {
        let resolver = NetworkVideoResolver()
        defer { resolver.cancel() }
        var result: Result<ResolvedNetworkVideo, NetworkVideoFailure>?
        resolver.resolve(try NetworkVideo("https://www.bilibili.com/video/BV1bK411W797?p=2")) { result = $0 }
        let deadline = Date().addingTimeInterval(75)
        while result == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard case .success(let media)? = result else {
            if case .failure(let error)? = result { Issue.record("resolution failed: \(error.localizedDescription)") }
            else { Issue.record("resolution deadline exceeded") }; return
        }
        #expect(media.request.key == "bilibili:BV1bK411W797:p2" && media.parts.count == 23)
        let window = PlayerWindowController()
        defer { window.shutdown() }
        let engine = try #require(window.engine)
        window.openNetwork(media)
        let loadDeadline = Date().addingTimeInterval(40)
        while window.loadedPath == nil && Date() < loadDeadline { try await Task.sleep(for: .milliseconds(50)) }
        let loaded = window.loadedPath != nil
        #expect(loaded, "must decode, not merely resolve")
        guard loaded else { return }
        #expect((engine.property("video-params/w").flatMap(Int.init) ?? 0) > 0)
        #expect(engine.property("audio-codec-name") != nil)
        #expect(window.sidebar.networkPartButtons.count == 23)
        engine.setSpeed(2); engine.seek(to: 12)
        let seekDeadline = Date().addingTimeInterval(12)
        while (engine.state.timePos < 11 || engine.state.speed != 2) && Date() < seekDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.state.timePos >= 11 && engine.state.speed == 2)
        engine.setPaused(true)
        let pauseDeadline = Date().addingTimeInterval(3)
        while !engine.state.isPaused && Date() < pauseDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(engine.state.isPaused)
        var extraOpens = 0
        window.onFileOpened = { _ in extraOpens += 1 }
        engine.seek(to: max(0, engine.state.duration - 0.2)); engine.setPaused(false)
        let eofDeadline = Date().addingTimeInterval(12)
        while !engine.state.eofReached && Date() < eofDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.state.eofReached && extraOpens == 0, "EOF must wait for explicit part selection")
    }
    @Test("BLL2 b23 public redirect produces canonical BV and part catalog",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOTOOL_BILIBILI_LIVE"] == "1"))
    func shortLink() async throws {
        let fetcher = BilibiliCatalogFetcher()
        defer { fetcher.cancel() }
        var result: Result<BilibiliCatalog, NetworkVideoFailure>?
        fetcher.fetch(try NetworkVideo("https://b23.tv/BV1bK411W797")) { result = $0 }
        let deadline = Date().addingTimeInterval(45)
        while result == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard case .success(let catalog)? = result else { Issue.record("public b23 redirect/catalog failed"); return }
        #expect(catalog.request.key == "bilibili:BV1bK411W797:p1" && catalog.parts.count == 23)
    }
}
