import AppKit
import Testing
@testable import VideoTool

/// Explicit opt-in only; never make offline regression gates depend on YouTube.
@Suite(.serialized) @MainActor struct YouTubeLiveTests {
    @Test("YL1 public YouTube resolves, decodes separate audio/video, seeks and pauses",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOTOOL_YOUTUBE_LIVE"] == "1"))
    func publicVideo() async throws {
        let resolver = NetworkVideoResolver()
        var result: Result<ResolvedNetworkVideo, NetworkVideoFailure>?
        resolver.resolve(try NetworkVideo("https://www.youtube.com/watch?v=M7lc1UVf-VE")) { result = $0 }
        let deadline = Date().addingTimeInterval(55)
        while result == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        defer { resolver.cancel() }
        guard case .success(let media)? = result else {
            if case .failure(let error)? = result { Issue.record("public resolution failed: \(error.localizedDescription)") }
            else { Issue.record("public resolution deadline exceeded") }
            return
        }
        let window = PlayerWindowController()
        defer { window.shutdown() }
        let engine = try #require(window.engine)
        let originalEvent = engine.onEvent
        engine.onEvent = { event in
            if case .log(let message) = event, message.hasPrefix("[network]") { print(message) }
            originalEvent?(event)
        }
        window.openNetwork(media)
        let loadDeadline = Date().addingTimeInterval(40)
        while window.loadedPath == nil && Date() < loadDeadline { try await Task.sleep(for: .milliseconds(50)) }
        // Boolean assertions deliberately avoid printing signed CDN URLs.
        let loaded = window.loadedPath != nil
        #expect(loaded, "public video must actually load, not merely resolve")
        guard loaded else { return }
        #expect((engine.property("video-params/w").flatMap(Int.init) ?? 0) > 0)
        #expect(engine.property("audio-codec-name") != nil)
        engine.setSpeed(2)
        engine.seek(to: 12)
        let seekDeadline = Date().addingTimeInterval(12)
        while (engine.state.timePos < 11 || engine.state.speed != 2) && Date() < seekDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.state.timePos >= 11 && engine.state.speed == 2)
        engine.setPaused(true)
        let pauseDeadline = Date().addingTimeInterval(3)
        while !engine.state.isPaused && Date() < pauseDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(engine.state.isPaused)
    }
}
