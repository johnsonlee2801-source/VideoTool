import Foundation
import Libmpv

enum MPVError: Error, LocalizedError {
    case createFailed
    case api(Int32, String)
    var errorDescription: String? {
        switch self {
        case .createFailed: return "mpv_create failed"
        case .api(let code, let what): return "\(what): \(String(cString: mpv_error_string(code)))"
        }
    }
}

/// libmpv wrapper. Commands go in asynchronously; property changes come back
/// on a private queue and are applied to `state` on the main thread.
final class MPVEngine: PlayerEngine {
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "io.github.johnsonlee2801-source.videotool.mpv-events")
    private let lock = NSLock()
    private var isShutDown = false

    private(set) var state = PlayerState() {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((PlayerState) -> Void)?
    var onEvent: ((PlayerEvent) -> Void)?

    init() throws {
        guard let h = mpv_create() else { throw MPVError.createFailed }
        // A failing initializer never runs deinit, so destroy the handle here.
        var initialized = false
        defer { if !initialized { mpv_destroy(h) } }
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", "auto-safe"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("config", "no"),
            ("terminal", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("ytdl", "no"),
            ("audio-pitch-correction", "yes"),
            ("volume-max", "100"),
        ]
        for (k, v) in options {
            let r = mpv_set_option_string(h, k, v)
            if r < 0 { throw MPVError.api(r, "set option \(k)") }
        }
        mpv_request_log_messages(h, "warn")
        let r = mpv_initialize(h)
        if r < 0 { throw MPVError.api(r, "mpv_initialize") }

        for p in MPVProperty.allCases {
            let r = mpv_observe_property(h, p.rawValue, p.name, p.format)
            if r < 0 { throw MPVError.api(r, "observe \(p.name)") }
        }
        handle = h
        initialized = true
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue().wakeup()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// PlaybackSession normally shuts down first (render context before mpv).
    deinit { shutdown() }

    /// Destroys mpv. Call through `PlaybackSession.shutdown()` so the render
    /// context is freed first. Holding `lock` makes destruction mutually
    /// exclusive with every other libmpv call; no `queue.sync`, so it cannot
    /// deadlock when invoked from the event queue.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        guard !isShutDown, let h = handle else { return }
        isShutDown = true
        mpv_set_wakeup_callback(h, nil, nil)
        mpv_terminate_destroy(h)
        handle = nil
    }

    // MARK: PlayerEngine

    func load(_ url: URL) { loadTarget(url.isFileURL ? url.path : url.absoluteString) }
    /// Anything mpv accepts: a path, a URL string, or an `av://lavfi:` source.
    func loadTarget(_ target: String) { command(["loadfile", target, "replace"]) }
    func stop() { command(["stop"]) }
    func setPaused(_ paused: Bool) { setFlag("pause", paused) }
    func togglePause() { command(["cycle", "pause"]) }
    func seek(to seconds: Double) { command(["seek", "\(max(0, seconds))", "absolute"]) }
    /// Fast keyframe seek for live scrubbing; the final position uses an exact seek.
    func scrub(to seconds: Double) { command(["seek", "\(max(0, seconds))", "absolute+keyframes"]) }
    func seek(by delta: Double) { command(["seek", "\(delta)", "relative"]) }
    func setSpeed(_ speed: Double) { setDouble("speed", min(max(speed, 0.1), 10)) }
    func setVolume(_ volume: Double) { setDouble("volume", min(max(volume, 0), 100)) }
    func toggleMute() { command(["cycle", "mute"]) }
    func cycleSubtitle() { command(["cycle", "sub"]) }
    /// Sound outputs as mpv sees them (speakers, headphones, AirPlay).
    func audioDevices() -> [AudioDevice] {
        let n = Int(property("audio-device-list/count") ?? "") ?? 0
        return (0..<n).compactMap { i in
            guard let name = property("audio-device-list/\(i)/name") else { return nil }
            return AudioDevice(name: name, description: property("audio-device-list/\(i)/description") ?? name)
        }
    }
    func setAudioDevice(_ name: String) { command(["set", "audio-device", name]) }

    /// Adds an external subtitle file and shows it (AI subtitles).
    func addSubtitle(path: String, title: String) { command(["sub-add", path, "select", title]) }
    func cycleAudio() { command(["cycle", "audio"]) }

    // MARK: commands & properties

    func command(_ args: [String]) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        withLiveHandle { h in
            let r = cargs.withUnsafeMutableBufferPointer { mpv_command_async(h, 0, $0.baseAddress) }
            report(r, "command \(args.first ?? "")")
        }
    }

    private func setDouble(_ name: String, _ value: Double) {
        var v = value
        withLiveHandle { h in report(mpv_set_property_async(h, 0, name, MPV_FORMAT_DOUBLE, &v), "set \(name)") }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        var v: Int32 = value ? 1 : 0
        withLiveHandle { h in report(mpv_set_property_async(h, 0, name, MPV_FORMAT_FLAG, &v), "set \(name)") }
    }

    /// Runs `body` with the handle while holding the lock, so `shutdown()`
    /// cannot destroy the handle mid-call. Does nothing after shutdown.
    /// Reads any mpv property as a string (track lists, codec names…). nil if unavailable.
    func property(_ name: String) -> String? {
        withHandle { h -> String? in
            guard let c = mpv_get_property_string(h, name) else { return nil }
            defer { mpv_free(c) }
            return String(cString: c)
        } ?? nil
    }

    /// Number of video, audio and subtitle tracks in the loaded file.
    func trackCounts() -> (video: Int, audio: Int, subtitle: Int) {
        let n = Int(property("track-list/count") ?? "") ?? 0
        var counts = (video: 0, audio: 0, subtitle: 0)
        for i in 0..<n {
            switch property("track-list/\(i)/type") {
            case "video": if property("track-list/\(i)/albumart") != "yes" { counts.video += 1 }
            case "audio": counts.audio += 1
            case "sub": counts.subtitle += 1
            default: break
            }
        }
        return counts
    }

    /// Locked access for collaborators (the render layer creates its render
    /// context against this handle).
    func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !isShutDown, let h = handle else { return nil }
        return body(h)
    }

    private func withLiveHandle(_ body: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !isShutDown, let h = handle else { return }
        body(h)
    }

    private func report(_ result: Int32, _ what: String) {
        guard result < 0 else { return }
        let text = "\(what) failed: \(String(cString: mpv_error_string(result)))"
        post(.log(text))
    }

    // MARK: events

    private func wakeup() {
        queue.async { [weak self] in self?.drainEvents() }
    }

    private func drainEvents() {
        while true {
            var done = true
            // The event's memory belongs to mpv and stays valid only until the
            // next mpv_wait_event on this handle, so handle it under the lock.
            withLiveHandle { h in
                guard let ev = mpv_wait_event(h, 0), ev.pointee.event_id != MPV_EVENT_NONE else { return }
                handleEvent(ev.pointee, h)
                done = false
            }
            if done { return }
        }
    }

    /// Called with the engine lock held (from drainEvents).
    private func handleEvent(_ e: mpv_event, _ h: OpaquePointer) {
        switch e.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = e.data, let prop = MPVProperty(rawValue: e.reply_userdata) else { return }
            let p = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            applyProperty(prop, p)
        case MPV_EVENT_FILE_LOADED:
            var path = ""
            if let c = mpv_get_property_string(h, "path") { path = String(cString: c); mpv_free(c) }
            var duration = 0.0
            if mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, &duration) < 0 { duration = 0 }
            post(.fileLoaded(path: path, duration: duration))
        case MPV_EVENT_COMMAND_REPLY, MPV_EVENT_SET_PROPERTY_REPLY:
            if e.error < 0 { post(.log("mpv async request failed: \(String(cString: mpv_error_string(e.error)))")) }
        case MPV_EVENT_END_FILE:
            guard let data = e.data else { return }
            let ef = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            post(.endFile(eof: ef.reason == MPV_END_FILE_REASON_EOF))
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = e.data else { return }
            let m = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let text = "[\(String(cString: m.prefix))] \(String(cString: m.level)): \(String(cString: m.text))"
            post(.log(text.trimmingCharacters(in: .newlines)))
        default:
            break
        }
    }

    private func applyProperty(_ prop: MPVProperty, _ p: mpv_event_property) {
        guard let value = MPVValue(p) else { return }       // copy now: mpv reuses the event memory
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = self.state
            if s.apply(prop, value) { self.state = s }
        }
    }

    private func post(_ event: PlayerEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
