import AppKit
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct SubtitleTranscriptLiveTests {
    @Test("SLive1 anonymous website captions load, display, search and seek in the native player",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOTOOL_SUBTITLE_LIVE"] == "1"))
    func publicCaptions() async throws {
        let resolver = NetworkVideoResolver(); defer { resolver.cancel() }
        var result: Result<ResolvedNetworkVideo, NetworkVideoFailure>?
        resolver.resolve(try NetworkVideo("https://youtu.be/M7lc1UVf-VE")) { result = $0 }
        #expect(await wait(55) { result != nil })
        guard case .success(let media)? = result else { Issue.record("Anonymous public video resolution failed"); return }
        let window = PlayerWindowController(); defer { window.shutdown() }
        window.openNetwork(media)
        #expect(await wait(40) { window.loadedPath != nil })
        guard window.loadedPath != nil else { return }
        window.showSubtitleTranscript(nil)
        let view = window.sidebar.transcript
        #expect(await wait(65) { view.document != nil || view.cancelButton.isHidden })
        if view.document == nil {
            print("Caption diagnostic: sources=\(window.transcriptCoordinator.sources.count), status=\(view.status.stringValue)")
        }
        let document = try #require(view.document)
        #expect(!document.cues.isEmpty)
        let engine = try #require(window.engine)
        #expect(await wait(8) { engine.property("sid") != "no" && (Int(engine.property("track-list/count") ?? "") ?? 0) > 2 })
        let cue = try #require(document.cues.first(where: { $0.start > 8 && $0.start < 40 }))
        view.searchField.stringValue = String(cue.text.prefix(5)); view.refreshQuery()
        #expect(await wait(5) { !view.isSearching })
        #expect(!view.rows.isEmpty)
        engine.setSpeed(1.5); view.onJump?(cue)
        #expect(await wait(12) { abs(engine.state.timePos - cue.start) < 2 && abs(engine.state.speed - 1.5) < 0.01 })
        #expect(!window.isMakingAISubtitles)
    }
    private func wait(_ seconds: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return predicate()
    }
}
