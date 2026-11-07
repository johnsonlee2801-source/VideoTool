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
    /// Once network media has played, also suppress late log events after a
    /// switch to local media. Raw libmpv logs can contain signed stream URLs.
    private var redactMediaLogs = false
    /// Playlist entry of the last START_FILE drained (read and written under `lock`).
    private var startedEntry: Int64?
    /// Bumped by every load request (under `lock`). A FILE_LOADED read before a newer
    /// request is delivered to the main thread after it, and must not count for it.
    private var loadGeneration = 0
    /// The playlist entry the latest load request created, from loadfile's reply (under `lock`).
    /// Until that reply arrives, any FILE_LOADED is from an older request.
    private enum LoadEntry { case awaitingReply, entry(Int64), failed, unknown }
    private var loadEntry = LoadEntry.unknown
    private static let loadReplyBase: UInt64 = 1 << 40

    private(set) var state = PlayerState() {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((PlayerState) -> Void)?
    var onEvent: ((PlayerEvent) -> Void)?

    /// Under the test runner the player makes no sound: tests must not play through
    /// the user's speakers, and opening the real output is slow while the screen is
    /// locked (2026-10-19: 16 s per file instead of 1 s). Audio is still decoded.
    static var testOptions: [(String, String)] { AppData.isTestRun ? [("ao", "null")] : [] }

    /// `extraOptions` come after the defaults (tests use them, e.g. ao=pcm).
    init(extraOptions: [(String, String)] = []) throws {
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
        ] + Self.testOptions + extraOptions
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
    func loadNetwork(_ media: ResolvedNetworkVideo) {
        command(media.loadCommand, loadRequest: true, redact: true)
    }
    /// Anything mpv accepts: a path, a URL string, or an `av://lavfi:` source.
    func loadTarget(_ target: String) { command(["loadfile", target, "replace"], loadRequest: true) }
    func stop() { command(["stop"]) }
    func setPaused(_ paused: Bool) { setFlag("pause", paused) }
    func togglePause() { command(["cycle", "pause"]) }
    func seek(to seconds: Double) { command(["seek", "\(max(0, seconds))", "absolute"]) }
    /// Fast keyframe seek for live scrubbing; the final position uses an exact seek.
    func scrub(to seconds: Double) { command(["seek", "\(max(0, seconds))", "absolute+keyframes"]) }
    /// Exact, like the bar: a keyframe seek can miss ±5 s by several seconds when
    /// keyframes are far apart (found 2026-10-19: "back 5 s" from 0:07 landed at 0:00).
    func seek(by delta: Double) { command(["seek", "\(delta)", "relative+exact"]) }
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
    /// The same file again (regenerated or reopened) is reloaded and selected, not added twice.
    /// `select: false` adds it without switching to it (the viewer had chosen otherwise).
    func addSubtitle(path: String, title: String, select: Bool = true) {
        if let id = subtitleTrackID(path: path) {
            command(["sub-reload", id])          // the file may have been rewritten since
            if select { command(["set", "sid", id]) }
            return
        }
        command(["sub-add", path, select ? "select" : "auto", title])
    }

    /// Loop playback between two times (nil: no loop).
    func setLoop(_ range: ClipRange?) {
        command(["set", "ab-loop-a", range.map { String($0.start) } ?? "no"])
        command(["set", "ab-loop-b", range.map { String($0.end) } ?? "no"])
    }

    /// Night mode on/off (see NightMode.filter).
    func setNightMode(_ on: Bool) {
        command(on ? ["af", "add", NightMode.filter] : ["af", "remove", "@night"])
    }

    func adjustSubtitleDelay(to seconds: Double) { command(["set", "sub-delay", String(seconds)]) }

    /// Track choice and timing for one video: "auto", "no" or a track id. These are
    /// global in mpv, so every opened video gets them set (nothing leaks between files).
    func applyTrackChoice(audio: String, subtitle: String, subtitleDelay: Double) {
        command(["set", "aid", audio])
        command(["set", "sid", subtitle])
        command(["set", "sub-delay", String(subtitleDelay)])
    }

    /// Re-reads an external subtitle file that was rewritten (subtitles made while playing).
    func reloadSubtitle(path: String) {
        if let id = subtitleTrackID(path: path) { command(["sub-reload", id]) }
    }

    func removeSubtitle(path: String) {
        if let id = subtitleTrackID(path: path) { command(["sub-remove", id]) }
    }

    private func subtitleTrackID(path: String) -> String? {
        let n = Int(property("track-list/count") ?? "") ?? 0
        for i in 0..<n where property("track-list/\(i)/type") == "sub"
            && property("track-list/\(i)/external-filename") == path {
            return property("track-list/\(i)/id")
        }
        return nil
    }
    func cycleAudio() { command(["cycle", "audio"]) }

    // MARK: commands & properties

    func command(_ args: [String]) { command(args, loadRequest: false) }

    /// A load request is numbered and sent under the same lock, so the reply and every
    /// event read afterwards can be matched to the request that is really the latest.
    private func command(_ args: [String], loadRequest: Bool, redact: Bool = false) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        withLiveHandle { h in
            var userdata: UInt64 = 0
            if loadRequest {
                if redact { redactMediaLogs = true }
                loadGeneration += 1; loadEntry = .awaitingReply
                userdata = Self.loadReplyBase + UInt64(loadGeneration)
            }
            let r = cargs.withUnsafeMutableBufferPointer { mpv_command_async(h, userdata, $0.baseAddress) }
            if r < 0 && loadRequest { loadEntry = .failed }
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
        case MPV_EVENT_START_FILE:
            if let data = e.data { startedEntry = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id }
        case MPV_EVENT_FILE_LOADED:
            // Events are read after the fact: if mpv already moved on to another entry,
            // its live path/duration belong to that entry, not to this event.
            // mpv's playback thread runs on, so check the entry before and after the reads.
            func playingEntry() -> Int64? {
                var position: Int64 = -1, id: Int64 = -1
                guard mpv_get_property(h, "playlist-playing-pos", MPV_FORMAT_INT64, &position) >= 0, position >= 0,
                      mpv_get_property(h, "playlist/\(position)/id", MPV_FORMAT_INT64, &id) >= 0 else { return nil }
                return id
            }
            switch loadEntry {
            case .awaitingReply, .failed: return              // from a request older than the latest
            case .entry(let id): guard startedEntry == id else { return }
            case .unknown: break
            }
            // Once START_FILE named the entry, an unreadable identity is not proof either.
            if let started = startedEntry, playingEntry() != started { return }
            var path = ""
            if let c = mpv_get_property_string(h, "path") { path = String(cString: c); mpv_free(c) }
            var duration = 0.0
            if mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, &duration) < 0 { duration = 0 }
            if let started = startedEntry, playingEntry() != started { return }
            post(.fileLoaded(path: path, duration: duration), ifStillGeneration: loadGeneration)
        case MPV_EVENT_COMMAND_REPLY, MPV_EVENT_SET_PROPERTY_REPLY:
            if e.event_id == MPV_EVENT_COMMAND_REPLY, e.reply_userdata > Self.loadReplyBase,
               e.reply_userdata - Self.loadReplyBase == UInt64(loadGeneration) {
                // The latest load's reply names the entry it created; older replies are ignored.
                if e.error < 0 { loadEntry = .failed }
                else if let data = e.data, let id = Self.playlistEntryID(data.assumingMemoryBound(to: mpv_event_command.self).pointee.result) { loadEntry = .entry(id) }
                else { loadEntry = .unknown }
            }
            if e.error < 0 { post(.log("mpv async request failed: \(String(cString: mpv_error_string(e.error)))")) }
        case MPV_EVENT_END_FILE:
            guard let data = e.data else { return }
            let ef = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            post(.endFile(eof: ef.reason == MPV_END_FILE_REASON_EOF))
            if ef.error < 0 {
                var path = ""
                // `path` has already been cleared after a failed open. Only use
                // the surviving playlist entry if its ID matches this event;
                // a late error from the replaced entry must not blame a new one.
                var entryID: Int64 = -1
                if mpv_get_property(h, "playlist/0/id", MPV_FORMAT_INT64, &entryID) >= 0,
                   entryID == ef.playlist_entry_id,
                   let c = mpv_get_property_string(h, "playlist/0/filename") {
                    path = String(cString: c); mpv_free(c)
                }
                post(.playbackFailed(path: path))
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = e.data else { return }
            let m = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            if redactMediaLogs {
                let message = String(cString: m.text)
                // Only fixed categories/status codes may leave the network engine.
                if let range = message.range(of: "HTTP error [0-9]{3}", options: .regularExpression) {
                    post(.log("[network] " + message[range]))
                } else {
                    for category in ["Protocol not found", "certificate", "Connection refused", "Connection timed out", "Failed to open", "Error parsing option", "Unrecognized option"] where message.localizedCaseInsensitiveContains(category) {
                        post(.log("[network] " + category)); break
                    }
                }
                return
            }
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

    /// `playlist_entry_id` from loadfile's result map (mpv 0.33+); nil if absent.
    private static func playlistEntryID(_ node: mpv_node) -> Int64? {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee, let keys = list.keys, let values = list.values else { return nil }
        for i in 0..<Int(list.num) where String(cString: keys[i]!) == "playlist_entry_id" && values[i].format == MPV_FORMAT_INT64 {
            return values[i].u.int64
        }
        return nil
    }
    private func post(_ event: PlayerEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
    /// Delivered only if no newer load was requested since the event was read.
    private func post(_ event: PlayerEvent, ifStillGeneration generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.loadGeneration; self.lock.unlock()
            guard current == generation else { return }
            self.onEvent?(event)
        }
    }
}
