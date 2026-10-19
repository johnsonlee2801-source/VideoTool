import AppKit
import Testing
@testable import VideoTool

// Fixed playback speeds (decision 2026-10-19): a speed menu next to the timeline,
// the chosen speed is remembered, and a hold starts above it (plan A, core A1-A8).
struct PlaybackSpeedTests {
    @Test("PS1 the presets young viewers use, in order") func presets() {
        #expect(PlaybackSpeed.presets == [0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0])
    }

    @Test("PS2 labels keep quarter steps exact: 1.25× is not shown as 1.3×") func labels() {
        #expect(PlaybackSpeed.label(1.0) == "1.0×")
        #expect(PlaybackSpeed.label(1.25) == "1.25×")
        #expect(PlaybackSpeed.label(0.75) == "0.75×")
        #expect(PlaybackSpeed.label(2.5) == "2.5×")
        #expect(PlaybackSpeed.label(1.7000000000000002) == "1.7×")
    }

    @Test("PS3 chosen speeds are kept in range and free of float noise") func normalized() {
        #expect(PlaybackSpeed.normalized(1.2000000000000002) == 1.2)
        #expect(PlaybackSpeed.normalized(0.1) == 0.5)
        #expect(PlaybackSpeed.normalized(9) == 6)
        #expect(PlaybackSpeed.normalized(.nan) == 1)
    }

    @Test("PS4 the chosen speed is remembered; bad stored values fall back to 1.0") func remembered() throws {
        let suite = "ps-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PreferredSpeedStore(defaults: defaults).speed == 1.0)
        PreferredSpeedStore(defaults: defaults).speed = 1.5
        #expect(PreferredSpeedStore(defaults: defaults).speed == 1.5)
        defaults.set(-3.0, forKey: PreferredSpeedStore.key)
        #expect(PreferredSpeedStore(defaults: defaults).speed == 1.0)
    }
}

@Suite(.serialized) @MainActor struct SpeedMenuTests {
    @Test("PS5 the speed menu lists every preset and ticks the current one") func menu() {
        let menu = PlaybackSpeed.menu(current: 1.5, target: nil, action: nil)
        #expect(menu.items.map(\.title) == ["0.75×", "1.0×", "1.25×", "1.5×", "2.0×", "2.5×", "3.0×"])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["1.5×"])
        #expect(menu.items.compactMap { $0.representedObject as? Double } == PlaybackSpeed.presets)
        #expect(PlaybackSpeed.menu(current: 1.7, target: nil, action: nil).items.allSatisfy { $0.state == .off })
    }

    @Test("PS6 choosing a speed, ] and ⌫ update the remembered speed; a hold does not")
    func choosingRemembers() async throws {
        let saved = PreferredSpeedStore().speed
        defer { PreferredSpeedStore().speed = saved }       // shared by every window in this run
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.perform(.setSpeed(2.5))
        #expect(w.preferredSpeed == 2.5)
        w.perform(.speedDelta(0.1))
        #expect(w.preferredSpeed == 2.6)
        w.perform(.resetSpeed)
        #expect(w.preferredSpeed == 1.0)
        // A real hold: button down past the 0.25 s threshold, then release.
        let view = try #require(w.playerView)
        view.gesture.mouseDown()
        let deadline = Date().addingTimeInterval(2)
        while !view.gesture.isHolding, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(view.gesture.isHolding, "the hold never started")
        view.gesture.mouseUp()
        #expect(w.preferredSpeed == 1.0)
    }
}
