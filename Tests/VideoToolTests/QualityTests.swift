import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VideoTool

// Picture and performance check (review study 2026-10-19). Skipped unless
// tools/quality_check.sh made the clips and touched the RUN marker (10 min).
// Plays each clip in a real, visible player window and measures what reviews of
// other players complain about: CPU/hardware decoding on 4K, dropped frames,
// seek latency, HDR handling. Results go to quality-results.json.

private let base = FileManager.default.temporaryDirectory.appendingPathComponent("videotool-quality")
private var requested: Bool {
    guard let date = (try? FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("RUN").path))?[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(date) < 600
}

/// With the display asleep or the screen locked, windows do not draw: every frame
/// counts as dropped and seeks wait for frames that are never shown. Found
/// 2026-10-19 (first run while the user was away): those numbers are meaningless then.
private var screenIsLive: Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    return CGDisplayIsAsleep(CGMainDisplayID()) == 0 && (session["CGSSessionScreenIsLocked"] as? Bool ?? false) == false
}

private func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

@MainActor
private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private final class Results: @unchecked Sendable {
    static let shared = Results()
    var clips: [String: [String: Any]] = [:]
    func save() {
        let data = try? JSONSerialization.data(withJSONObject: clips, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: base.appendingPathComponent("quality-results.json"))
    }
}

@Suite(.serialized, .enabled(if: requested)) @MainActor struct QualityTests {
    struct Measured {
        var hwdec: String
        var cpuPercent: Double
        var dropped: Int
        var frames: Int
        var seekMedianMs: Double
        var seekMaxMs: Double
        var scrubMedianMs: Double
        var gamma: String
        var primaries: String
    }

    private func measure(_ name: String) async throws -> Measured {
        let url = base.appendingPathComponent("clips/\(name)")
        try #require(FileManager.default.fileExists(atPath: url.path), "run tools/quality_check.sh")
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.window?.setContentSize(NSSize(width: 1280, height: 772))
        w.showWindow(nil)
        w.open(url)
        let engine = try #require(w.engine)
        #expect(await waitUntil(10) { engine.state.path == url.path && engine.state.duration > 0 })
        engine.setSpeed(1)
        engine.setPaused(false)
        _ = await waitUntil(1.5) { false }                         // warm up

        // 1. steady playback: CPU of this process and dropped frames over 6 s
        let fps = Double(engine.property("container-fps") ?? "") ?? 0
        let drop0 = (Int(engine.property("frame-drop-count") ?? "") ?? 0) + (Int(engine.property("decoder-frame-drop-count") ?? "") ?? 0)
        let c0 = cpuSeconds(), t0 = Date()
        _ = await waitUntil(6) { false }
        let wall = Date().timeIntervalSince(t0)
        let cpu = (cpuSeconds() - c0) / wall * 100
        let drop1 = (Int(engine.property("frame-drop-count") ?? "") ?? 0) + (Int(engine.property("decoder-frame-drop-count") ?? "") ?? 0)
        let hwdec = engine.property("hwdec-current") ?? "?"
        let gamma = engine.property("video-params/gamma") ?? "?"
        let primaries = engine.property("video-params/primaries") ?? "?"

        // 2. seeking: exact jumps (clicking the bar, ⌥← / stars) and keyframe scrubs (dragging)
        func latency(_ go: (Double) -> Void, _ target: Double) async -> Double {
            let t = Date()
            go(target)
            _ = await waitUntil(5) { engine.property("seeking") == "yes" || abs(engine.state.timePos - target) < 0.5 }
            _ = await waitUntil(5) { engine.property("seeking") == "no" && abs(engine.state.timePos - target) < 12 }
            return Date().timeIntervalSince(t) * 1000
        }
        let duration = engine.state.duration
        let targets = [0.73, 0.21, 0.55, 0.9, 0.35, 0.62].map { $0 * duration }
        var seeks: [Double] = [], scrubs: [Double] = []
        for t in targets { seeks.append(await latency({ engine.seek(to: $0) }, t)) }
        for t in targets { scrubs.append(await latency({ engine.scrub(to: $0) }, t)) }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }

        let m = Measured(hwdec: hwdec, cpuPercent: cpu, dropped: drop1 - drop0, frames: Int(fps * wall),
                         seekMedianMs: median(seeks), seekMaxMs: seeks.max() ?? 0, scrubMedianMs: median(scrubs),
                         gamma: gamma, primaries: primaries)
        Results.shared.clips[name] = ["screenLive": screenIsLive, "hwdec": m.hwdec, "cpuPercentOfOneCore": (m.cpuPercent * 10).rounded() / 10,
                                      "droppedFrames": m.dropped, "framesPlayed": m.frames,
                                      "seekMedianMs": m.seekMedianMs.rounded(), "seekMaxMs": m.seekMaxMs.rounded(),
                                      "scrubMedianMs": m.scrubMedianMs.rounded(), "gamma": m.gamma, "primaries": m.primaries]
        Results.shared.save()
        return m
    }

    @Test("Q1 4K HEVC 10-bit HDR10: hardware decoding, recognised as HDR (PQ, BT.2020), smooth, quick seeks")
    func hdr10() async throws {
        let m = try await measure("hdr10_4k_hevc10.mkv")
        #expect(m.hwdec.contains("videotoolbox"), "hwdec: \(m.hwdec)")
        #expect(m.gamma == "pq" && m.primaries == "bt.2020", "\(m.gamma) / \(m.primaries)")
        #expect(m.cpuPercent < 100, "CPU \(m.cpuPercent)% of one core")
        guard screenIsLive else { return }          // frames and seeks need a visible window
        #expect(Double(m.dropped) <= max(2, Double(m.frames) * 0.02), "\(m.dropped) of \(m.frames) frames dropped")
        #expect(m.seekMedianMs < 400 && m.seekMaxMs < 1500, "seek median \(m.seekMedianMs) ms, max \(m.seekMaxMs) ms")
    }

    @Test("Q2 4K 60 fps H.264 at 60 Mbit/s: hardware decoding, no dropped frames worth noticing")
    func h264HighBitrate() async throws {
        let m = try await measure("h264_4k60_high.mp4")
        #expect(m.hwdec.contains("videotoolbox"), "hwdec: \(m.hwdec)")
        #expect(m.cpuPercent < 100, "CPU \(m.cpuPercent)% of one core")
        guard screenIsLive else { return }          // frames and seeks need a visible window
        #expect(Double(m.dropped) <= max(2, Double(m.frames) * 0.02), "\(m.dropped) of \(m.frames) frames dropped")
        #expect(m.seekMedianMs < 400 && m.seekMaxMs < 1500, "seek median \(m.seekMedianMs) ms, max \(m.seekMaxMs) ms")
    }

    @Test("Q3 1080p HEVC with 10 s between keyframes: dragging stays responsive")
    func longGOP() async throws {
        let m = try await measure("hevc_1080_longgop.mp4")
        guard screenIsLive else { return }
        #expect(m.scrubMedianMs < 250, "scrub median \(m.scrubMedianMs) ms")
        #expect(m.seekMedianMs < 1000 && m.seekMaxMs < 2500, "seek median \(m.seekMedianMs) ms, max \(m.seekMaxMs) ms")
    }
}
