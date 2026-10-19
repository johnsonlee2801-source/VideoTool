import Foundation
import Libmpv

/// Copies a video's soundtrack to a 16 kHz mono WAV file for speech recognition,
/// with its own short-lived libmpv instance (any format mpv plays, MKV included).
/// mpv's pcm audio output writes the file itself, so no FFmpeg encoder is needed,
/// and `untimed` makes it run far faster than real time (60 s of audio in ~0.2 s).
/// Synchronous: call from a background queue.
enum AudioExtractor {
    enum Failure: Error, Equatable {
        case cannotOpen(String)
        case noAudio
        case cancelled
    }

    /// Returns the audio duration in seconds.
    static func extract(source: String, to wav: URL, isCancelled: () -> Bool = { false },
                        progress: (Double) -> Void = { _ in }) -> Result<Double, Failure> {
        try? FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: wav)
        guard let h = mpv_create() else { return .failure(.cannotOpen("mpv_create failed")) }
        let outcome = run(h, source: source, wav: wav, isCancelled: isCancelled, progress: progress)
        // The WAV is complete (header sizes written) only once mpv has shut down.
        mpv_terminate_destroy(h)
        switch outcome {
        case .failure(let f):
            try? FileManager.default.removeItem(at: wav)
            return .failure(f)
        case .success:
            // A WAV header alone (44 bytes) means there was no sound to write.
            let size = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
            guard size > 44 else {
                try? FileManager.default.removeItem(at: wav)
                return .failure(.noAudio)
            }
            progress(1)
            return .success(Double(size - 44) / 32_000)          // 16 kHz × 2 bytes, mono
        }
    }

    private static func run(_ h: OpaquePointer, source: String, wav: URL, isCancelled: () -> Bool,
                            progress: (Double) -> Void) -> Result<Void, Failure> {
        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("idle", "yes"), ("ytdl", "no"), ("osd-level", "0"),
            ("vo", "null"), ("vid", "no"), ("sid", "no"),
            ("ao", "pcm"), ("ao-pcm-file", wav.path), ("ao-pcm-waveheader", "yes"),
            ("audio-samplerate", "16000"), ("audio-channels", "mono"), ("audio-format", "s16"),
            ("untimed", "yes"), ("keep-open", "no"),
        ]
        for (k, v) in options where mpv_set_option_string(h, k, v) < 0 {
            return .failure(.cannotOpen("option \(k)"))
        }
        guard mpv_initialize(h) >= 0 else { return .failure(.cannotOpen("initialize")) }

        var args: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")), UnsafePointer(strdup(source)), nil]
        defer { args.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        guard args.withUnsafeMutableBufferPointer({ mpv_command(h, $0.baseAddress) }) >= 0 else {
            return .failure(.cannotOpen("loadfile"))
        }

        var duration = 0.0
        var loaded = false
        var endError: Int32 = 0
        loop: while true {
            if isCancelled() {
                var stop: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("stop")), nil]
                _ = stop.withUnsafeMutableBufferPointer { mpv_command(h, $0.baseAddress) }
                stop.forEach { free(UnsafeMutablePointer(mutating: $0)) }
                return .failure(.cancelled)
            }
            guard let ev = mpv_wait_event(h, 0.1) else { continue }
            switch ev.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = true
                if mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, &duration) < 0 { duration = 0 }
            case MPV_EVENT_END_FILE:
                if let d = ev.pointee.data {
                    endError = d.assumingMemoryBound(to: mpv_event_end_file.self).pointee.error
                }
                break loop
            case MPV_EVENT_SHUTDOWN:
                break loop
            default:
                break
            }
            var pos = 0.0
            if loaded, duration > 0, mpv_get_property(h, "audio-pts", MPV_FORMAT_DOUBLE, &pos) >= 0 {
                progress(min(max(pos / duration, 0), 1))
            }
        }
        // With video switched off, a file without sound has "nothing to play".
        if endError == MPV_ERROR_NOTHING_TO_PLAY.rawValue { return .failure(.noAudio) }
        guard loaded, endError >= 0 else { return .failure(.cannotOpen(String(cString: mpv_error_string(endError)))) }
        return .success(())
    }
}
