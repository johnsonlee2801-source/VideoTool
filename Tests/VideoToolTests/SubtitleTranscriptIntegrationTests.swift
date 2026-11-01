import AppKit
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct SubtitleTranscriptIntegrationTests {
    @Test("SI1 real mpv subtitle search jumps and phrase replay retain speed and delay")
    func playback() async throws {
        let window = PlayerWindowController(); defer { window.shutdown() }
        let fixture = try #require(Bundle(for: TranscriptFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let engine = try #require(window.engine)
        window.open(fixture)
        #expect(await wait { window.loadedPath != nil })
        let loader = TranscriptLoaderStub(); window.transcriptCoordinator.loader = loader
        window.showSubtitleTranscript(nil)
        loader.sourcesCompletion?(.success([SubtitleSourceOption(id: "srt", title: "Test", input: .file(fixture.deletingPathExtension().appendingPathExtension("srt"), bilingual: false))]))
        loader.loadCompletion?(.success(SubtitleTranscript(cues: [SubtitleCue(start: 4, end: 6, text: "First"), SubtitleCue(start: 9, end: 12, text: "Second") ])))
        let view = window.sidebar.transcript
        engine.setSpeed(1.5); window.subtitleLater(nil)
        view.onJump?(try #require(view.document?.cues.last))
        #expect(await wait { engine.state.timePos >= 8.8 && engine.state.timePos < 11 })
        #expect(abs(engine.state.speed - 1.5) < 0.01)
        engine.seek(to: 6); #expect(await wait { engine.state.timePos >= 5.9 && engine.state.timePos < 8 })
        view.onReplay?()
        #expect(await wait { engine.state.timePos >= 3.8 && engine.state.timePos < 5.5 })
        window.open(fixture)
        #expect(view.document == nil && window.transcriptCoordinator.documentTarget == nil)
    }
    @Test("SI2 installed ffprobe and ffmpeg extract the bundled embedded subtitle as timed text")
    func embedded() async throws {
        let fixture = try #require(Bundle(for: TranscriptFixtureMarker.self).url(forResource: "multi_audio_subs", withExtension: "mkv"))
        let loader = SubtitleContentLoader(); defer { loader.cancel() }
        var sources: [SubtitleSourceOption]?
        var failure: SubtitleLoadFailure?
        loader.localSources(fixture) { if case .success(let rows) = $0 { sources = rows }; if case .failure(let error) = $0 { failure = error } }
        #expect(await wait { sources != nil || failure != nil })
        let source = try #require(sources?.first)
        var document: SubtitleTranscript?
        loader.load(source.input) { if case .success(let value) = $0 { document = value }; if case .failure(let error) = $0 { failure = error } }
        #expect(await wait { document != nil || failure != nil })
        #expect(document?.cues.isEmpty == false && failure == nil)
    }
    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(40)) }
        return predicate()
    }
}
private final class TranscriptFixtureMarker: NSObject {}
