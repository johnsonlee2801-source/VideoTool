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

/// RMS of the 16-bit mono WAV mpv writes for `source` at `speed` (0 = silent).
private func loudness(at speed: Double) throws -> (rms: Double, seconds: Double) {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("speed-\(speed)-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let h = try #require(mpv_create())
    for (k, v) in [("config", "no"), ("terminal", "no"), ("vo", "null"), ("vid", "no"), ("ao", "pcm"),
                   ("ao-pcm-file", wav.path), ("audio-samplerate", "16000"), ("audio-channels", "mono"),
                   ("audio-format", "s16"), ("untimed", "yes"), ("speed", String(speed))] {
        mpv_set_option_string(h, k, v)
    }
    mpv_initialize(h)
    var args: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")), UnsafePointer(strdup(speech)), nil]
    _ = args.withUnsafeMutableBufferPointer { mpv_command(h, $0.baseAddress) }
    args.forEach { free(UnsafeMutablePointer(mutating: $0)) }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, let ev = mpv_wait_event(h, 0.2), ev.pointee.event_id != MPV_EVENT_END_FILE {}
    mpv_terminate_destroy(h)
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
    func audibleAtHighSpeed() throws {
        let normal = try loudness(at: 1)
        #expect(normal.rms > 300, "the fixture must have speech: rms \(normal.rms)")
        for speed in [2.0, 3.0, 4.0, 5.0, 6.0] {
            let fast = try loudness(at: speed)
            #expect(fast.rms > normal.rms * 0.4, "\(speed)x: rms \(fast.rms) vs \(normal.rms) at 1x — muted?")
            #expect(abs(fast.seconds - normal.seconds / speed) < 0.5, "\(speed)x lasted \(fast.seconds) s")
        }
    }
}
