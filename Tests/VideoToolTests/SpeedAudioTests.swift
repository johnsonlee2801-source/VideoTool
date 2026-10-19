import Foundation
import Libmpv
import Testing
@testable import VideoTool
import VideoToolCore

// Review study 2026-10-19: users of other players complain that sound cuts out at
// high speed. Our gesture goes up to 6x; render the soundtrack at several speeds
// with mpv's default audio chain (as the player uses it) and measure loudness.
private final class Marker {}
private let speech = Bundle(for: Marker.self).path(forResource: "speech-en", ofType: "mkv")!

/// RMS of the 16-bit mono WAV the player's own engine (MPVEngine, with its audio
/// settings) writes for the speech clip at `speed` (0 = silent). The sound goes to
/// a file instead of the speakers; nothing else about the engine changes.
@MainActor
private func loudness(at speed: Double) async throws -> (rms: Double, seconds: Double) {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("speed-\(speed)-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let engine = try MPVEngine(extraOptions: [("vo", "null"), ("vid", "no"), ("ao", "pcm"), ("ao-pcm-file", wav.path),
                                              ("audio-samplerate", "16000"), ("audio-channels", "mono"),
                                              ("audio-format", "s16"), ("untimed", "yes"), ("keep-open", "no")])
    engine.setSpeed(speed)
    var ended = false
    engine.onEvent = { if case .endFile = $0 { ended = true } }
    engine.load(URL(fileURLWithPath: speech))
    engine.setPaused(false)
    let deadline = Date().addingTimeInterval(20)
    while !ended, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    engine.shutdown()                                       // finishes the WAV
    let samples = try Data(contentsOf: wav).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1)))
    return (rms, Double(samples.count) / 16000)
}

@Suite(.serialized) struct SpeedAudioTests {
    @Test("SA2 the gesture's top speed stays below where mpv's pitch-keeping filter mutes (8x)")
    func capBelowMute() {
        #expect(SpeedGestureOptions.defaults.maxSpeed <= 8)
        #expect((PlaybackSpeed.presets.max() ?? 0) <= 8 && PlaybackSpeed.range.upperBound <= 8)
    }

    @Test("SA1 speech stays audible at every speed the gesture can reach, and gets shorter as expected")
    @MainActor func audibleAtHighSpeed() async throws {
        let normal = try await loudness(at: 1)
        #expect(normal.rms > 300, "the fixture must have speech: rms \(normal.rms)")
        for speed in [2.0, 3.0, 4.0, 5.0, 6.0] {
            let fast = try await loudness(at: speed)
            #expect(fast.rms > normal.rms * 0.4, "\(speed)x: rms \(fast.rms) vs \(normal.rms) at 1x — muted?")
            #expect(abs(fast.seconds - normal.seconds / speed) < 0.5, "\(speed)x lasted \(fast.seconds) s")
        }
    }
}
