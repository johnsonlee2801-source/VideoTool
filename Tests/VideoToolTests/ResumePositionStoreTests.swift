import Foundation
import Testing
@testable import VideoTool

@Suite(.serialized) struct ResumePositionStoreTests {
    private func makeStore(now: @escaping () -> Date = Date.init) -> (ResumePositionStore, UserDefaults) {
        let suite = "videotool.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ResumePositionStore(defaults: defaults, now: now), defaults)
    }
    private let a = URL(fileURLWithPath: "/Movies/a.mkv")
    private let b = URL(fileURLWithPath: "/Movies/b.mp4")

    @Test("save then read back, per file") func roundTrip() {
        let (store, _) = makeStore()
        #expect(store.position(for: a) == nil)
        store.save(123.5, for: a)
        store.save(7, for: b)
        #expect(store.position(for: a) == 123.5)
        #expect(store.position(for: b) == 7)
    }

    @Test("clear removes only that file") func clear() {
        let (store, _) = makeStore()
        store.save(10, for: a); store.save(20, for: b)
        store.clear(for: a)
        #expect(store.position(for: a) == nil)
        #expect(store.position(for: b) == 20)
    }

    @Test("survives a new store instance on the same defaults") func persists() {
        let (store, defaults) = makeStore()
        store.save(42, for: a)
        let again = ResumePositionStore(defaults: defaults)
        #expect(again.position(for: a) == 42)
    }

    @Test("rejects garbage positions") func garbage() {
        let (store, _) = makeStore()
        store.save(-1, for: a); store.save(.nan, for: a); store.save(.infinity, for: a)
        #expect(store.position(for: a) == nil)
    }

    @Test("keeps at most 500 entries, dropping the oldest") func prunes() {
        var t: TimeInterval = 0
        let (store, _) = makeStore(now: { t += 1; return Date(timeIntervalSince1970: t) })
        for i in 0..<(ResumePositionStore.maxEntries + 20) {
            store.save(Double(i), for: URL(fileURLWithPath: "/m/\(i).mp4"))
        }
        #expect(store.count == ResumePositionStore.maxEntries)
        #expect(store.position(for: URL(fileURLWithPath: "/m/0.mp4")) == nil, "oldest dropped")
        #expect(store.position(for: URL(fileURLWithPath: "/m/519.mp4")) == 519, "newest kept")
    }

    @Test("resumeTarget: nothing stored, too early, or too close to the end means start over") func resumeRules() {
        #expect(ResumePositionStore.resumeTarget(position: nil, duration: 100) == nil)
        #expect(ResumePositionStore.resumeTarget(position: 4.9, duration: 100) == nil)
        #expect(ResumePositionStore.resumeTarget(position: 5, duration: 100) == 5)
        #expect(ResumePositionStore.resumeTarget(position: 90, duration: 100) == 90)
        #expect(ResumePositionStore.resumeTarget(position: 90.1, duration: 100) == nil)
        #expect(ResumePositionStore.resumeTarget(position: 50, duration: 0) == 50, "unknown duration: trust the position")
        #expect(ResumePositionStore.resumeTarget(position: .nan, duration: 100) == nil)
    }
}
