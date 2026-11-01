import AppKit
import Testing
@testable import VideoTool

@Suite @MainActor struct SubtitleTranscriptCoordinatorTests {
    @Test("SC3 late sources and documents cannot cross video identity or survive cancellation")
    func staleCallbacks() throws {
        let view = SubtitleTranscriptView(frame: .zero), loader = TranscriptLoaderStub(), catalog = TranscriptCatalogStub()
        let coordinator = SubtitleTranscriptCoordinator(view: view, loader: loader, catalog: catalog)
        let a = SubtitleTranscriptContext(target: "a", local: URL(fileURLWithPath: "/a.mp4"), network: nil, external: [], preferredSource: nil)
        let b = SubtitleTranscriptContext(target: "b", local: URL(fileURLWithPath: "/b.mp4"), network: nil, external: [], preferredSource: nil)
        coordinator.open(a); let old = try #require(loader.sourcesCompletion)
        coordinator.open(b)
        old(.success([SubtitleSourceOption(id: "old", title: "old", input: .file(URL(fileURLWithPath: "/old.srt"), bilingual: false))]))
        #expect(coordinator.sources.isEmpty)
        loader.sourcesCompletion?(.success([SubtitleSourceOption(id: "b", title: "b", input: .file(URL(fileURLWithPath: "/b.srt"), bilingual: false))]))
        let pending = try #require(loader.loadCompletion)
        coordinator.cancelRead()
        pending(.success(SubtitleTranscript(cues: [SubtitleCue(start: 1, end: 3, text: "stale")])))
        #expect(view.document == nil && coordinator.documentTarget == nil)
    }
    @Test("SC4 overlay keeps existing sidebar tab, width and search state")
    func overlay() {
        let sidebar = PlayerSidebarView(bookmarks: BookmarkListView(), preferences: nil, history: WatchHistoryStore(), libraryProvider: { nil }, onOpen: { _ in })
        sidebar.show(.recent); sidebar.resize(to: 330)
        sidebar.showTranscript()
        #expect(sidebar.isTranscriptOpen && sidebar.state.tab == .recent && sidebar.state.preferredWidth == 330)
        sidebar.hideTranscript()
        #expect(!sidebar.isTranscriptOpen && sidebar.state.tab == .recent)
        sidebar.showTranscript(); sidebar.show(.stars)
        #expect(!sidebar.isTranscriptOpen && sidebar.state.tab == .stars)
        sidebar.shutdown()
    }
}
final class TranscriptLoaderStub: SubtitleContentLoading {
    var sourcesCompletion: ((Result<[SubtitleSourceOption], SubtitleLoadFailure>) -> Void)?
    var loadCompletion: ((Result<SubtitleTranscript, SubtitleLoadFailure>) -> Void)?
    func localSources(_ video: URL, completion: @escaping (Result<[SubtitleSourceOption], SubtitleLoadFailure>) -> Void) { sourcesCompletion = completion }
    func load(_ input: SubtitleInput, completion: @escaping (Result<SubtitleTranscript, SubtitleLoadFailure>) -> Void) { loadCompletion = completion }
    func cancel() {}
}
final class TranscriptCatalogStub: NetworkCaptionCatalogLoading {
    func resolve(_ video: NetworkVideo, completion: @escaping (Result<[NetworkCaptionTrack], NetworkVideoFailure>) -> Void) {}
    func cancel() {}
}
