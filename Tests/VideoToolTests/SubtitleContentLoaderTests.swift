import Foundation
import Testing
@testable import VideoTool

@Suite @MainActor struct SubtitleContentLoaderTests {
    @Test("SL1 probing and conversion use real stream indices with a file-only protocol policy")
    func commandsAndCancellation() throws {
        var processes: [CaptionProcessStub] = []
        let loader = SubtitleContentLoader(ffmpeg: { URL(fileURLWithPath: "/tools/ffmpeg") }, ffprobe: { URL(fileURLWithPath: "/tools/ffprobe") }, makeProcess: { let p = CaptionProcessStub(); processes.append(p); return p })
        var sources: [SubtitleSourceOption] = []
        loader.localSources(URL(fileURLWithPath: "/movie.mkv")) { if case .success(let rows) = $0 { sources = rows } }
        processes[0].completion?(.success(Data(#"{"streams":[{"index":3,"tags":{"language":"en"}}]}"#.utf8)))
        #expect(sources.first?.id == "embedded:3")
        var callbacks = 0
        loader.load(try #require(sources.first?.input)) { _ in callbacks += 1 }
        #expect(processes[1].args.contains("0:3") && processes[1].args.contains("file,pipe"))
        #expect(processes[1].args.suffix(3) == ["-f", "srt", "pipe:1"])
        loader.cancel()
        processes[1].completion?(.success(Data("1\n00:00:01,000 --> 00:00:03,000\nhello\n".utf8)))
        #expect(callbacks == 0 && processes[1].cancelled)
    }
    @Test("SL3 cancellation can discard inline subtitle parsing before it publishes a result")
    func cancelInline() async throws {
        let loader = SubtitleContentLoader()
        let track = NetworkCaptionTrack(id: "en", title: "Caption", format: "srt", site: .youtube, url: nil, inline: "1\n00:00:01,000 --> 00:00:03,000\nhello\n", headers: [:])
        var callbacks = 0
        loader.load(.website(track)) { _ in callbacks += 1 }
        loader.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(callbacks == 0)
    }
    @Test("SL2 absent tools and non-caption paths fail explicitly without launching a process")
    func unavailableTools() {
        let loader = SubtitleContentLoader(ffmpeg: { nil }, ffprobe: { nil })
        var failure: SubtitleLoadFailure?
        loader.localSources(URL(fileURLWithPath: "/movie.mkv")) { if case .failure(let error) = $0 { failure = error } }
        #expect(failure == .missingFFmpeg)
        #expect(SubtitleContentLoader.localURL(URL(fileURLWithPath: "/config.json"), video: false) == nil)
        #expect(SubtitleContentLoader.localURL(URL(string: "https://example.test/movie.mp4")!, video: true) == nil)
    }
}
private final class CaptionProcessStub: NetworkVideoProcessRunning {
    var args: [String] = []
    var cancelled = false
    var completion: ((Result<Data, NetworkVideoFailure>) -> Void)?
    func run(executable: URL, arguments: [String], completion: @escaping (Result<Data, NetworkVideoFailure>) -> Void) { args = arguments; self.completion = completion }
    func cancel() { cancelled = true }
}
