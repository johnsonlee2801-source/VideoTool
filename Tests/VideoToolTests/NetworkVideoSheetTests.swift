import AppKit
import Testing
@testable import VideoTool

private final class SheetResolver: YouTubeResolving {
    var requests: [YouTubeVideo] = []
    var completions: [(Result<ResolvedYouTubeVideo, YouTubeFailure>) -> Void] = []
    var cancels = 0
    func resolve(_ video: YouTubeVideo, completion: @escaping (Result<ResolvedYouTubeVideo, YouTubeFailure>) -> Void) {
        requests.append(video); completions.append(completion)
    }
    func cancel() { cancels += 1 }
}

@Suite(.serialized) @MainActor struct NetworkVideoSheetTests {
    @Test("YS1 native submit validates input, shows progress, and allows retry after failure")
    func inputAndRetry() throws {
        let resolver = SheetResolver()
        var opened = 0
        let sheet = NetworkVideoSheet(resolver: resolver) { _ in opened += 1 }
        defer { sheet.cancel() }
        sheet.urlField.stringValue = "https://evil.test/video"
        #expect(NSApp.sendAction(#selector(NetworkVideoSheet.submit(_:)), to: sheet, from: sheet.openButton))
        #expect(resolver.requests.isEmpty && !sheet.status.stringValue.isEmpty)
        sheet.urlField.stringValue = "https://youtu.be/BaW_jenozKc"
        sheet.submit(nil)
        #expect(sheet.isResolving && !sheet.openButton.isEnabled && resolver.requests.count == 1)
        resolver.completions[0](.failure(.failed))
        #expect(!sheet.isResolving && sheet.openButton.isEnabled && opened == 0)
        sheet.submit(nil)
        #expect(resolver.requests.count == 2)
        let media = ResolvedYouTubeVideo(request: resolver.requests[1], title: "Video", videoURL: URL(string: "https://r.googlevideo.com/v")!, audioURL: nil, headers: [:])
        resolver.completions[1](.success(media))
        resolver.completions[1](.success(media))
        #expect(opened == 1)
    }

    @Test("YS2 cancel and local open discard late successful resolution")
    func cancelAndLocalOpen() throws {
        let resolver = SheetResolver(), window = PlayerWindowController()
        defer { window.shutdown() }
        let sheet = window.presentNetworkVideo("https://youtu.be/BaW_jenozKc", resolver: resolver)
        sheet.submit(nil)
        #expect(sheet.isResolving)
        let sample = try #require(Bundle(for: SheetFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        var opens: [URL] = []
        window.onFileOpened = { opens.append($0) }
        window.open(sample)
        let media = ResolvedYouTubeVideo(request: resolver.requests[0], title: "Late", videoURL: URL(string: "https://r.googlevideo.com/v")!, audioURL: nil, headers: [:])
        resolver.completions[0](.success(media))
        #expect(!sheet.isResolving && resolver.cancels > 0)
        #expect(opens == [sample])
    }
}

private final class SheetFixtureMarker {}
