import AppKit
import Testing
@testable import VideoTool

private final class SheetResolver: NetworkVideoResolving {
    var requests: [NetworkVideo] = []
    var completions: [(Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void] = []
    var cancels = 0
    func resolve(_ video: NetworkVideo, completion: @escaping (Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void) {
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
        #expect(!sheet.browserButton.isHidden && sheet.browserURL?.host == "www.youtube.com")
        sheet.submit(nil)
        #expect(resolver.requests.count == 2)
        let media = ResolvedNetworkVideo(request: resolver.requests[1], title: "Video", videoURL: URL(string: "https://r.googlevideo.com/v")!, audioURL: nil, headers: [:])
        resolver.completions[1](.success(media))
        resolver.completions[1](.success(media))
        #expect(opened == 1)
    }

    @Test("BS2 selecting a sidebar part resolves explicitly and local opens clear the part list")
    func sidebarSelection() throws {
        let resolver = SheetResolver(), window = PlayerWindowController()
        defer { window.shutdown() }
        window.networkResolverFactory = { resolver }
        let fixture = try #require(Bundle(for: SheetFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let request = try NetworkVideo("https://bilibili.com/video/BV1bK411W797")
        var media = ResolvedNetworkVideo(request: request, title: "one", videoURL: fixture, audioURL: nil, headers: [:])
        media.parts = [BilibiliPart(page: 1, title: "one"), BilibiliPart(page: 2, title: "two")]
        var opens = 0
        window.onFileOpened = { _ in opens += 1 }
        window.openNetwork(media)
        #expect(opens == 1 && resolver.requests.isEmpty)
        window.sidebar.networkPartButtons[1].performClick(nil)
        #expect(resolver.requests.map(\.key) == ["bilibili:BV1bK411W797:p2"])
        #expect(opens == 1, "pending resolution must leave current playback intact")
        window.open(fixture)
        #expect(window.sidebar.networkPartButtons.isEmpty)
        let late = ResolvedNetworkVideo(request: resolver.requests[0], title: "late", videoURL: fixture, audioURL: nil, headers: [:])
        resolver.completions[0](.success(late))
        #expect(opens == 2 && window.sidebar.networkPartButtons.isEmpty)
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
        let media = ResolvedNetworkVideo(request: resolver.requests[0], title: "Late", videoURL: URL(string: "https://r.googlevideo.com/v")!, audioURL: nil, headers: [:])
        resolver.completions[0](.success(media))
        #expect(!sheet.isResolving && resolver.cancels > 0)
        #expect(opens == [sample])
    }
}

private final class SheetFixtureMarker {}
