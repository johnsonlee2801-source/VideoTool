import AppKit
import Testing
import Libmpv
@testable import VideoTool

@Suite(.serialized) @MainActor struct YouTubePlaybackTests {
    @Test("NE6 retry resolves fresh media and restores interruption time instead of the original link start")
    func networkRecovery() async throws {
        let fixture = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let request = try NetworkVideo("https://youtu.be/M7lc1UVf-VE?t=2")
        let media = ResolvedNetworkVideo(request: request, title: "Recovery", videoURL: fixture, audioURL: nil, headers: [:])
        let resolver = RecoveryResolver(), window = PlayerWindowController()
        defer { window.shutdown() }
        window.networkResolverFactory = { resolver }
        let engine = try #require(window.engine)
        window.openNetwork(media)
        #expect(await wait { window.loadedPath != nil })
        var state = engine.state
        state.path = fixture.path; state.timePos = 9; state.isBuffering = true; state.videoHeight = 720
        engine.onStateChange?(state)
        #expect(window.networkMessage?.contains(L("正在缓冲…")) == true)
        engine.onEvent?(.playbackFailed(path: fixture.path))
        #expect(!window.networkRetryButton.isHidden)
        window.networkRetryButton.performClick(nil)
        #expect(resolver.requests.count == 1 && resolver.requests[0].start == nil)
        resolver.completion?(.success(ResolvedNetworkVideo(request: resolver.requests[0], title: "Recovered", videoURL: fixture, audioURL: nil, headers: [:])))
        #expect(await wait { window.loadedPath != nil && engine.state.timePos >= 8.5 })
        #expect(window.networkRetryButton.isHidden)
    }
    @Test("CW4 continuing and restarting a network record control the real playback position")
    func continueNetwork() async throws {
        let fixture = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let request = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        let resolver = RecoveryResolver(), window = PlayerWindowController()
        defer { window.shutdown() }
        window.networkResolverFactory = { resolver }
        let item = ContinueWatchingItem(url: request.url, title: "Lecture", position: 8, watchedAt: Date())
        window.openContinue(item, fromBeginning: false)
        resolver.completion?(.success(ResolvedNetworkVideo(request: request, title: "Lecture", videoURL: fixture, audioURL: nil, headers: [:])))
        let engine = try #require(window.engine)
        #expect(await wait { window.loadedPath != nil && engine.state.timePos >= 7.5 })
        window.openContinue(item, fromBeginning: true)
        resolver.completion?(.success(ResolvedNetworkVideo(request: request, title: "Lecture restart", videoURL: fixture, audioURL: nil, headers: [:])))
        #expect(await wait { window.loadedPath != nil && engine.state.timePos < 2 })
    }
    @Test("A6 a continue or retry position belongs to its own video; a different resolved video starts by its own rules")
    func positionStaysWithItsVideo() async throws {
        let fixture = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let original = try NetworkVideo("https://youtu.be/M7lc1UVf-VE"), replacement = try NetworkVideo("https://youtu.be/BaW_jenozKc")
        let name = "videotool-tests-continue-other-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let resolver = RecoveryResolver()
        let window = PlayerWindowController(history: WatchHistoryStore(defaults: defaults), resumeStore: ResumePositionStore(defaults: defaults), networkHistory: NetworkWatchHistoryStore(defaults: defaults))
        defer { window.shutdown() }
        window.networkResolverFactory = { resolver }
        let engine = try #require(window.engine)
        // The first resolution failed, the viewer edited the link in the sheet, and it resolved to another video.
        window.openContinue(ContinueWatchingItem(url: original.url, title: "A", position: 12, watchedAt: Date()), fromBeginning: false)
        resolver.completion?(.success(ResolvedNetworkVideo(request: replacement, title: "B", videoURL: fixture, audioURL: nil, headers: [:])))
        #expect(await wait { window.loadedPath != nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state.timePos < 3, "B inherited A's position: \(engine.state.timePos)")
        window.openNetwork(ResolvedNetworkVideo(request: original, title: "A", videoURL: fixture, audioURL: nil, headers: [:]))
        #expect(await wait { window.loadedPath != nil })
        var state = engine.state; state.path = fixture.path; state.timePos = 12; engine.onStateChange?(state)
        engine.onEvent?(.playbackFailed(path: fixture.path))
        window.networkRetryButton.performClick(nil)
        resolver.completion?(.success(ResolvedNetworkVideo(request: replacement, title: "B", videoURL: fixture, audioURL: nil, headers: [:])))
        #expect(await wait { window.loadedPath != nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state.timePos < 3, "retry into B inherited A's interruption: \(engine.state.timePos)")
    }
    @Test("A21 a retry that fails before playing keeps the interruption time for the next retry")
    func repeatedRetryKeepsPosition() async throws {
        let fixture = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let request = try NetworkVideo("https://youtu.be/M7lc1UVf-VE")
        let resolver = RecoveryResolver(), window = PlayerWindowController()
        defer { window.shutdown() }
        window.networkResolverFactory = { resolver }
        let engine = try #require(window.engine)
        window.openNetwork(ResolvedNetworkVideo(request: request, title: "R", videoURL: fixture, audioURL: nil, headers: [:]))
        #expect(await wait { window.loadedPath != nil })
        var state = engine.state; state.path = fixture.path; state.timePos = 9; engine.onStateChange?(state)
        engine.onEvent?(.playbackFailed(path: fixture.path))
        window.networkRetryButton.performClick(nil)
        resolver.completion?(.success(ResolvedNetworkVideo(request: request, title: "R", videoURL: fixture, audioURL: nil, headers: [:])))
        // This attempt fails at once, before mpv reports any position.
        engine.onEvent?(.playbackFailed(path: fixture.path))
        window.networkRetryButton.performClick(nil)
        resolver.completion?(.success(ResolvedNetworkVideo(request: request, title: "R", videoURL: fixture, audioURL: nil, headers: [:])))
        #expect(await wait { window.loadedPath != nil && engine.state.timePos >= 8.5 }, "second retry: loaded=\(String(describing: window.loadedPath)) pos=\(engine.state.timePos) path=\(String(describing: engine.state.path)) requests=\(resolver.requests.count) msg=\(String(describing: window.networkMessage)) retryHidden=\(window.networkRetryButton.isHidden)")
    }
    @Test("CW6 local continue and from-start use the selected position without affecting network history")
    func continueLocal() async throws {
        let fixture = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let name = "videotool-tests-continue-local-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let network = NetworkWatchHistoryStore(defaults: defaults)
        let window = PlayerWindowController(history: WatchHistoryStore(defaults: defaults), resumeStore: ResumePositionStore(defaults: defaults), networkHistory: network)
        defer { window.shutdown() }
        let item = ContinueWatchingItem(url: fixture, title: "Local", position: 8, watchedAt: Date())
        window.openContinue(item, fromBeginning: false)
        let engine = try #require(window.engine)
        #expect(await wait { window.loadedPath != nil && engine.state.timePos >= 7.5 })
        window.openContinue(item, fromBeginning: true)
        #expect(await wait { window.loadedPath != nil && engine.state.timePos < 2 })
        #expect(network.entries.isEmpty)
    }
    @Test("YP1 resume keys distinguish YouTube IDs and keep local paths unchanged")
    func resumeIdentity() throws {
        let name = "videotool-tests-youtube-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ResumePositionStore(defaults: defaults)
        let first = try NetworkVideo("https://youtu.be/BaW_jenozKc").url
        let second = try NetworkVideo("https://youtu.be/M7lc1UVf-VE").url
        store.save(31, for: first)
        #expect(store.position(for: second) == nil)
        #expect(store.position(for: first) == 31)
        let local = URL(fileURLWithPath: "/watch")
        store.save(9, for: local)
        #expect(store.position(for: first) == 31 && store.position(for: local) == 9)
    }

    @Test("YP2 remote stars persist by video ID, discard late fingerprints and never generate local thumbnails")
    func remoteStars() throws {
        let store = try BookmarkStore(path: TestTemp.directory.appendingPathComponent("yt-\(UUID().uuidString).sqlite").path)
        let engine = FakeEngine(), background = ManualQueue(), thumbs = FakeThumbnailMaker()
        let controller = BookmarkController(store: store, engine: engine, thumbnails: thumbs,
            fingerprint: { _ in "osh:late" }, background: { background.submit($0) }, main: { $0() })
        controller.open(path: "/old.mp4")
        controller.openNetwork(try NetworkVideo("https://youtu.be/BaW_jenozKc"))
        background.runAll()
        #expect(controller.fileKey == "youtube:BaW_jenozKc")
        engine.state.timePos = 8
        _ = controller.toggleAtCurrentTime()
        #expect(thumbs.requests.isEmpty)
        controller.fileClosed()
        controller.openNetwork(try NetworkVideo("https://www.youtube.com/watch?v=BaW_jenozKc&list=ignored"))
        #expect(controller.bookmarks.map(\.time) == [8])
        engine.state.timePos = 0
        controller.jumpToNext()
        #expect(engine.seeks.last == 6)
    }

    @Test("YP3 actual mpv accepts scoped title/audio options and restores them for local playback")
    func separatedAudio() async throws {
        let fixture = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let request = try NetworkVideo("https://youtu.be/TESTnet0001?t=6")
        let audio = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "speech-en", withExtension: "mkv"))
        let media = ResolvedNetworkVideo(request: request, title: "Test, 日本語", videoURL: fixture, audioURL: audio,
                                        headers: ["User-Agent": "Test Agent", "Accept": "video/mp4, video/webm"])
        let name = "videotool-tests-youtube-window-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = WatchHistoryStore(defaults: defaults)
        let resumes = ResumePositionStore(defaults: defaults)
        resumes.save(9, for: request.url)
        let window = PlayerWindowController(history: history, resumeStore: resumes)
        defer { window.shutdown() }
        let engine = try #require(window.engine)
        window.openNetwork(media)
        #expect(await wait { window.loadedPath == fixture.path && engine.state.timePos >= 5.5 })
        #expect(engine.property("force-media-title") == "Test, 日本語")
        #expect(engine.property("tls-verify") == "yes")
        #expect(try headerFields(engine) == ["Accept: video/mp4, video/webm", "User-Agent: Test Agent"])
        #expect((engine.property("track-list/count").flatMap(Int.init) ?? 0) >= 2)
        #expect(window.previousVideoPath == nil && window.nextVideoPath == nil)
        #expect(history.all.isEmpty && window.sidebar.currentPath == nil)
        window.markClip(nil)
        #expect(window.markersForTesting.clipStart == nil, "keyboard C cannot expose local-only export controls for network video")
        engine.setPaused(true)
        #expect(await wait { engine.state.isPaused })
        window.open(fixture)
        #expect(await wait { window.loadedPath == fixture.path })
        #expect(engine.property("force-media-title") != "Test, 日本語")
        #expect(try headerFields(engine).isEmpty)
        let saved = resumes.position(for: request.url) ?? -1
        #expect(saved >= 5.5 && saved < 8, "explicit link time must replace old resume on close")
        #expect(!history.all.keys.contains(where: { $0.contains("youtube") || $0.hasPrefix("file:") }))
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func headerFields(_ engine: MPVEngine) throws -> [String] {
        var node = mpv_node()
        let handle = try #require(engine.handle)
        let result = mpv_get_property(handle, "http-header-fields", MPV_FORMAT_NODE, &node)
        defer { mpv_free_node_contents(&node) }
        #expect(result >= 0)
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { Issue.record("expected native string list"); return [] }
        return (0..<Int(list.pointee.num)).compactMap { index in
            let item = list.pointee.values[index]
            return item.format == MPV_FORMAT_STRING ? item.u.string.map { String(cString: $0) } : nil
        }
    }

    @Test("YP5 a failed stream shows a visible error without waiting for the loading deadline")
    func visibleLoadFailure() async throws {
        let window = PlayerWindowController()
        defer { window.shutdown() }
        let media = ResolvedNetworkVideo(request: try NetworkVideo("https://youtu.be/TESTnet0003"), title: "Missing",
            videoURL: TestTemp.directory.appendingPathComponent("missing-network-probe.mp4"), audioURL: nil, headers: [:])
        window.openNetwork(media)
        #expect(await wait { window.networkMessage == L("网络视频加载失败，可从中断处重试。") })
    }

    @Test("YP6 link times below five seconds survive initially unknown stream duration")
    func earlyTimestamp() async throws {
        let sample = try #require(Bundle(for: NetworkFixtureMarker.self).url(forResource: "testsrc-20s", withExtension: "mp4"))
        let window = PlayerWindowController()
        defer { window.shutdown() }
        let engine = try #require(window.engine)
        let original = engine.onEvent
        engine.onEvent = { event in
            if case .fileLoaded(let path, _) = event { original?(.fileLoaded(path: path, duration: 0)) }
            else { original?(event) }
        }
        window.openNetwork(ResolvedNetworkVideo(request: try NetworkVideo("https://youtu.be/TESTnet0004?t=2"),
                                               title: "Early", videoURL: sample, audioURL: nil, headers: [:]))
        #expect(await wait { window.loadedPath != nil })
        engine.setPaused(true)
        #expect(await wait { engine.state.isPaused && engine.state.timePos >= 1.8 && engine.state.timePos < 2.5 })
    }

    @Test("YP4 network engine diagnostics never expose transient media targets")
    func privateDiagnostics() async throws {
        let engine = try MPVEngine(extraOptions: [("vo", "null")])
        defer { engine.shutdown() }
        var logs: [String] = [], ended = false
        engine.onEvent = {
            if case .log(let line) = $0 { logs.append(line) }
            if case .endFile = $0 { ended = true }
        }
        let media = ResolvedNetworkVideo(request: try NetworkVideo("https://youtu.be/TESTnet0002"), title: "Missing",
            videoURL: TestTemp.directory.appendingPathComponent("probe-sensitive-marker-missing.mp4"), audioURL: nil, headers: [:])
        engine.loadNetwork(media)
        #expect(await wait { ended })
        #expect(!logs.contains { $0.contains("probe-sensitive-marker") })
    }
}

private final class NetworkFixtureMarker {}

private final class RecoveryResolver: NetworkVideoResolving {
    var requests: [NetworkVideo] = []
    var completion: ((Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void)?
    func resolve(_ video: NetworkVideo, completion: @escaping (Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void) { requests.append(video); self.completion = completion }
    func cancel() {}
}
