import Foundation
import Testing
@testable import VideoTool

// Resume-position bookkeeping, extracted from PlayerWindowController so it can
// be tested. History: switching files wrote A's position under B; the resume
// seek used the previous file's duration; EOF never cleared; a stale pre-seek
// position overwrote the stored one; and correctness depended on whether mpv
// delivered FILE_LOADED before or after the `path` property change.
// `fileLoaded(path:duration:)` now carries the file's own path and duration,
// read by the engine at FILE_LOADED time, so event order no longer matters.

private func state(_ path: String?, pos: Double, dur: Double, paused: Bool = false, eof: Bool = false) -> PlayerState {
    PlayerState(isPaused: paused, speed: 1, timePos: pos, duration: dur, path: path, isIdle: path == nil, eofReached: eof)
}

@Suite struct ResumeTrackerTests {
    @Test("R1 saves every 5 s of playback for the loaded file") func savesPeriodically() {
        var t = ResumeTracker(storedPosition: { _ in nil })
        #expect(t.fileLoaded(path: "/a.mp4", duration: 100) == [])
        #expect(t.update(state("/a.mp4", pos: 3, dur: 100)) == [])
        #expect(t.update(state("/a.mp4", pos: 6, dur: 100)) == [.save(path: "/a.mp4", position: 6)])
        #expect(t.update(state("/a.mp4", pos: 8, dur: 100)) == [])
        #expect(t.update(state("/a.mp4", pos: 11.5, dur: 100)) == [.save(path: "/a.mp4", position: 11.5)])
    }

    @Test("R2 switching files: no save between the switch and B's load, then saves go under B only") func switchingFiles() {
        var t = ResumeTracker(storedPosition: { _ in nil })
        _ = t.fileLoaded(path: "/a.mp4", duration: 100)
        _ = t.update(state("/a.mp4", pos: 40, dur: 100))
        // path flips to B while A's time-pos / duration are still in the state
        let actions = t.update(state("/b.mp4", pos: 40, dur: 100)) + t.update(state("/b.mp4", pos: 45, dur: 100))
        #expect(actions.isEmpty, "no save of any kind between the switch and B's fileLoaded: \(actions)")
        #expect(t.fileLoaded(path: "/b.mp4", duration: 300) == [])
        #expect(t.update(state("/b.mp4", pos: 6, dur: 300)) == [.save(path: "/b.mp4", position: 6)])
    }

    @Test("R2b order-independent: fileLoaded(B) before the path property flips; A's late ticks are ignored")
    func fileLoadedBeforePathChange() {
        var t = ResumeTracker(storedPosition: { _ in nil })
        _ = t.fileLoaded(path: "/a.mp4", duration: 100)
        _ = t.update(state("/a.mp4", pos: 40, dur: 100))
        _ = t.fileLoaded(path: "/b.mp4", duration: 300)
        #expect(t.update(state("/a.mp4", pos: 47, dur: 100)) == [], "late tick from A must not be saved")
        _ = t.update(state("/b.mp4", pos: 0, dur: 300))
        #expect(t.update(state("/b.mp4", pos: 6, dur: 300)) == [.save(path: "/b.mp4", position: 6)])
        #expect(t.finalAction(state("/b.mp4", pos: 10, dur: 300)) == .save(path: "/b.mp4", position: 10))
    }

    @Test("R3 resume seek uses the duration reported with the load, and seeks once") func resumeUsesLoadDuration() {
        var t = ResumeTracker(storedPosition: { $0 == "/b.mp4" ? 30 : nil })
        #expect(t.fileLoaded(path: "/b.mp4", duration: 600) == [.seek(30)])
        #expect(t.update(state("/b.mp4", pos: 30.2, dur: 600)) == [])
        #expect(t.update(state("/b.mp4", pos: 30.4, dur: 600)) == [], "seek only once")
    }

    @Test("R3b unknown duration at load (stream): waits for the first positive duration of this file")
    func resumeWaitsForDuration() {
        var t = ResumeTracker(storedPosition: { _ in 30 })
        #expect(t.fileLoaded(path: "/b.mp4", duration: 0) == [])
        #expect(t.update(state("/a.mp4", pos: 0, dur: 100)) == [], "another file's duration is ignored")
        #expect(t.update(state("/b.mp4", pos: 0, dur: 0)) == [])
        #expect(t.update(state("/b.mp4", pos: 0, dur: 600)) == [.seek(30)])
    }

    @Test("R4 a stored position inside the file's last 10 s does not seek") func tailMargin() {
        var t = ResumeTracker(storedPosition: { _ in 95 })
        #expect(t.fileLoaded(path: "/b.mp4", duration: 100) == [])
    }

    @Test("R5 reaching EOF clears the stored position once") func eofClears() {
        var t = ResumeTracker(storedPosition: { _ in nil })
        _ = t.fileLoaded(path: "/a.mp4", duration: 20)
        #expect(t.update(state("/a.mp4", pos: 20, dur: 20, paused: true, eof: true)) == [.clear(path: "/a.mp4")])
        #expect(t.update(state("/a.mp4", pos: 20, dur: 20, paused: true, eof: true)) == [])
    }

    @Test("R6 nothing is saved while paused or before fileLoaded") func noSaveWhilePausedOrLoading() {
        var t = ResumeTracker(storedPosition: { _ in nil })
        #expect(t.update(state("/a.mp4", pos: 30, dur: 100)) == [], "before fileLoaded")
        _ = t.fileLoaded(path: "/a.mp4", duration: 100)
        #expect(t.update(state("/a.mp4", pos: 50, dur: 100, paused: true)) == [])
    }

    @Test("R7 closing: final action saves mid-file, clears at EOF, does nothing without a loaded file") func finalAction() {
        var t = ResumeTracker(storedPosition: { _ in nil })
        #expect(t.finalAction(state(nil, pos: 0, dur: 0)) == nil)
        _ = t.fileLoaded(path: "/a.mp4", duration: 100)
        #expect(t.finalAction(state("/a.mp4", pos: 42, dur: 100)) == .save(path: "/a.mp4", position: 42))
        #expect(t.finalAction(state("/a.mp4", pos: 100, dur: 100, eof: true)) == .clear(path: "/a.mp4"))
        #expect(t.finalAction(state("/b.mp4", pos: 42, dur: 100)) == nil, "state of another file")
    }

    @Test("R8 seeking backwards re-arms saving immediately") func backwardsSeek() {
        var t = ResumeTracker(storedPosition: { _ in nil })
        _ = t.fileLoaded(path: "/a.mp4", duration: 100)
        _ = t.update(state("/a.mp4", pos: 60, dur: 100))
        #expect(t.update(state("/a.mp4", pos: 20, dur: 100)) == [.save(path: "/a.mp4", position: 20)])
    }

    @Test("R9 after the resume seek, nothing is saved until playback has landed near the target")
    func noSaveBeforeSeekLands() {
        var t = ResumeTracker(storedPosition: { _ in 300 })
        #expect(t.fileLoaded(path: "/b.mp4", duration: 600) == [.seek(300)])
        #expect(t.update(state("/b.mp4", pos: 0.5, dur: 600)) == [], "stale pre-seek position must not overwrite 300")
        #expect(t.update(state("/b.mp4", pos: 1.0, dur: 600)) == [])
        #expect(t.update(state("/b.mp4", pos: 300.1, dur: 600)) == [], "landed; next save after 5 s")
        #expect(t.update(state("/b.mp4", pos: 306, dur: 600)) == [.save(path: "/b.mp4", position: 306)])
    }

    @Test("R10 a resume seek that never lands stops blocking saves after a bounded number of updates")
    func seekGivesUp() {
        var t = ResumeTracker(storedPosition: { _ in 300 })
        _ = t.fileLoaded(path: "/b.mp4", duration: 600)
        var saved: [ResumeTracker.Action] = []
        for i in 0..<(ResumeTracker.seekLandingBudget + 20) {
            saved += t.update(state("/b.mp4", pos: Double(i) * 0.5, dur: 600))
        }
        #expect(!saved.isEmpty, "saving resumes eventually")
    }

    @Test("R11 invariant over random event sequences: every action names the most recently loaded file")
    func onlyLoadedPathIsEverNamed() {
        var rng = SystemRandomNumberGenerator()
        let paths = ["/a.mp4", "/b.mp4", "/c.mp4", nil]
        for _ in 0..<300 {
            var t = ResumeTracker(storedPosition: { _ in Double.random(in: 0...200, using: &rng) })
            var loaded: String?
            for _ in 0..<60 {
                if Int.random(in: 0..<6, using: &rng) == 0, let p = paths.randomElement(using: &rng)! {
                    loaded = p
                    for a in t.fileLoaded(path: p, duration: Double.random(in: 0...300, using: &rng)) {
                        if case .seek = a { continue }
                        Issue.record("fileLoaded produced \(a)")
                    }
                } else {
                    let s = state(paths.randomElement(using: &rng)!, pos: Double.random(in: 0...300, using: &rng),
                                  dur: Double.random(in: 0...300, using: &rng),
                                  paused: Bool.random(using: &rng), eof: Int.random(in: 0..<10, using: &rng) == 0)
                    for a in t.update(s) {
                        switch a {
                        case .save(let p, _), .clear(let p): #expect(p == loaded && p == s.path, "\(a) vs loaded \(String(describing: loaded))")
                        case .seek: #expect(s.path == loaded)
                        }
                    }
                }
            }
        }
    }
}
