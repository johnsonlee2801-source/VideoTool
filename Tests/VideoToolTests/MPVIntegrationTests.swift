import AppKit
import Foundation
import Testing
@testable import VideoTool

// Integration tests against the real libmpv. No window needed.

// 20 s 640x360 H.264 test pattern (made with mpv's lavfi testsrc). MPVKit's
// FFmpeg has no lavfi device, so the tests use a real file. It is read from the
// test bundle, NOT from the source tree: the repo sits on ~/Desktop, and every
// ad-hoc-signed rebuild would block in open() on macOS's Desktop-access prompt.
private final class BundleMarker {}
private let sample: String = Bundle(for: BundleMarker.self)
    .path(forResource: "testsrc-20s", ofType: "mp4") ?? "missing-fixture-testsrc-20s.mp4"

/// Polls until `condition` holds or the timeout passes. Must be async: the
/// engine delivers state with DispatchQueue.main.async, and spinning the run
/// loop from inside a main-queue block cannot drain the (serial) main queue.
@MainActor
private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite(.serialized) @MainActor struct MPVIntegrationTests {
    @Test("I1 render layer has a render context immediately, before any draw")
    func renderContextIsEager() throws {
        let engine = try MPVEngine()
        let layer = MPVRenderLayer(engine: engine)
        #expect(layer.isReady, "a file loaded right after launch must find a render context (smoke test 2026-10-18)")
        layer.teardown()
        engine.shutdown()
    }

    @Test("I2 a file loaded right after setup starts playing (no 'No render context set')")
    func loadsAndPlays() async throws {
        let engine = try MPVEngine()
        let layer = MPVRenderLayer(engine: engine)
        var events: [PlayerEvent] = []
        engine.onEvent = { events.append($0) }
        engine.loadTarget(sample)
        let loaded = await waitUntil { events.contains { if case .fileLoaded = $0 { return true } else { return false } } }
        #expect(loaded, "fileLoaded never arrived; events: \(events)")
        engine.setPaused(false)
        #expect(await waitUntil { engine.state.timePos > 0.2 }, "time-pos did not advance: \(engine.state)")
        #expect(!events.contains { if case .log(let l) = $0 { return l.contains("No render context") } else { return false } })
        layer.teardown()
        engine.shutdown()
    }

    @Test("I3 speed set by the gesture path reaches mpv and comes back in state")
    func speedRoundTrip() async throws {
        let engine = try MPVEngine()
        let layer = MPVRenderLayer(engine: engine)
        engine.loadTarget(sample)
        engine.setSpeed(2.4)
        #expect(await waitUntil { abs(engine.state.speed - 2.4) < 1e-9 }, "speed=\(engine.state.speed)")
        engine.setSpeed(1.0)
        #expect(await waitUntil { abs(engine.state.speed - 1.0) < 1e-9 })
        layer.teardown()
        engine.shutdown()
    }

    @Test("I4 shutdown is idempotent and commands after it are ignored")
    func shutdownTwice() throws {
        let engine = try MPVEngine()
        let layer = MPVRenderLayer(engine: engine)
        layer.teardown()
        engine.shutdown()
        engine.shutdown()
        engine.togglePause()
        engine.setSpeed(3)
        #expect(engine.handle == nil)
    }

    @Test("I5 session teardown frees the render context before destroying mpv, and is idempotent")
    func sessionShutdownOrder() throws {
        let session = try PlaybackSession()
        #expect(session.renderLayer.isReady)
        session.shutdown()
        #expect(!session.renderLayer.isReady)
        #expect(session.engine.handle == nil)
        session.shutdown()
    }

    @Test("I6 commands racing shutdown from many threads never touch a destroyed handle")
    func commandsRaceShutdown() throws {
        for _ in 0..<5 {
            let session = try PlaybackSession()
            let engine = session.engine
            engine.loadTarget(sample)
            let group = DispatchGroup()
            for i in 0..<8 {
                DispatchQueue.global().async(group: group) {
                    let end = Date().addingTimeInterval(0.25)
                    var n = 0
                    while Date() < end {
                        n += 1
                        if i % 2 == 0 { engine.setSpeed(1 + Double(n % 10) / 10) } else { engine.seek(by: 0.01) }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.08)
            session.shutdown()
            group.wait()
            #expect(engine.handle == nil)
        }
    }

    @Test("I7 pause and togglePause round-trip through real mpv")
    func pauseRoundTrip() async throws {
        let session = try PlaybackSession()
        let engine = session.engine
        engine.loadTarget(sample)
        engine.setPaused(true)
        #expect(await waitUntil { engine.state.isPaused })
        engine.togglePause()
        #expect(await waitUntil { !engine.state.isPaused })
        session.shutdown()
    }

    @Test("I8 keep-open: playing to the end sets eofReached, and loading another file resets it")
    func eofReachedLifecycle() async throws {
        let session = try PlaybackSession()
        let engine = session.engine
        engine.loadTarget(sample)
        #expect(await waitUntil { engine.state.duration > 0 })
        engine.seek(to: engine.state.duration - 0.3)
        engine.setPaused(false)
        #expect(await waitUntil(8) { engine.state.eofReached }, "\(engine.state)")
        engine.loadTarget(sample)
        #expect(await waitUntil { !engine.state.eofReached && engine.state.timePos < 5 }, "\(engine.state)")
        session.shutdown()
    }

    @Test("I9 FILE_LOADED carries the new file's own path and duration (resume no longer depends on event order)")
    func fileLoadedCarriesPathAndDuration() async throws {
        let session = try PlaybackSession()
        let engine = session.engine
        var loads: [PlayerEvent] = []
        engine.onEvent = { if case .fileLoaded = $0 { loads.append($0) } }
        engine.loadTarget(sample)
        #expect(await waitUntil { !loads.isEmpty })
        guard case .fileLoaded(let path, let duration)? = loads.first else { Issue.record("no fileLoaded"); return }
        #expect(path == sample)
        #expect(abs(duration - 20) < 0.5, "duration=\(duration)")
        session.shutdown()
    }

    @Test("I10 end to end with real mpv: a stored position is resumed and saving continues for that file")
    func resumeEndToEnd() async throws {
        let session = try PlaybackSession()
        let engine = session.engine
        var tracker = ResumeTracker(storedPosition: { $0 == sample ? 8 : nil })
        var saved: [ResumeTracker.Action] = []
        func apply(_ actions: [ResumeTracker.Action]) {
            for a in actions {
                if case .seek(let t) = a { engine.seek(to: t) } else { saved.append(a) }
            }
        }
        engine.onEvent = { if case .fileLoaded(let p, let d) = $0 { apply(tracker.fileLoaded(path: p, duration: d)); engine.setPaused(false) } }
        engine.onStateChange = { apply(tracker.update($0)) }
        engine.loadTarget(sample)
        #expect(await waitUntil { engine.state.timePos >= 7.5 && engine.state.timePos < 12 }, "\(engine.state)")
        engine.setSpeed(4)
        #expect(await waitUntil(8) { saved.contains { if case .save(let p, let pos) = $0 { return p == sample && pos >= 13 } else { return false } } },
                "\(saved)")
        #expect(!saved.contains { if case .save(_, let pos) = $0 { return pos < 7 } else { return false } }, "stale pre-seek save: \(saved)")
        session.shutdown()
    }

    @Test("I11 thumbnails come from a separate software-decoding mpv, so they work even when playback uses VideoToolbox")
    func thumbnailExtraction() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).jpg")
        let ok: Bool = await withCheckedContinuation { cont in
            MPVThumbnailMaker().makeThumbnail(source: sample, at: 5, to: out) { cont.resume(returning: $0) }
        }
        #expect(ok, "\(MPVThumbnailMaker.lastFailure ?? "")")
        guard ok else { return }
        let data = try Data(contentsOf: out)
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF], "JPEG magic")
        #expect(data.count > 1000)
        let image = try #require(NSImage(contentsOf: out))
        #expect(image.size.width <= CGFloat(MPVThumbnailMaker.width) + 1, "scaled down: \(image.size)")
    }

    @Test("I12 a thumbnail request for a missing file reports failure instead of hanging")
    func thumbnailMissingFile() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).jpg")
        let ok: Bool = await withCheckedContinuation { cont in
            MPVThumbnailMaker().makeThumbnail(source: "/nonexistent/\(UUID()).mp4", at: 1, to: out) { cont.resume(returning: $0) }
        }
        #expect(!ok)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("I13 glue end to end: the real fixture opened through BookmarkController gets its content key and stars persist")
    func bookmarksEndToEnd() async throws {
        let session = try PlaybackSession()
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).sqlite").path
        let controller = BookmarkController(store: try BookmarkStore(path: db), engine: session.engine, thumbnails: nil)
        controller.open(path: sample)
        #expect(await waitUntil { controller.fileKey != nil })
        #expect(controller.fileKey == "osh:58658fd4882cf11c")
        _ = controller.toggleAtCurrentTime()
        let again = BookmarkController(store: try BookmarkStore(path: db), engine: session.engine, thumbnails: nil)
        again.open(path: sample)
        #expect(await waitUntil { again.bookmarks.count == 1 })
        session.shutdown()
    }

    @Test("I14 a star at the very end of the video still yields a thumbnail or fails cleanly")
    func thumbnailAtEnd() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).jpg")
        let ok: Bool = await withCheckedContinuation { cont in
            MPVThumbnailMaker().makeThumbnail(source: sample, at: 20.0, to: out) { cont.resume(returning: $0) }
        }
        #expect(ok == FileManager.default.fileExists(atPath: out.path))
    }
}
