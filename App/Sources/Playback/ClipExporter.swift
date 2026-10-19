import CoreGraphics
import Foundation
import ImageIO
import Libmpv
import UniformTypeIdentifiers

/// A stretch of a video, in seconds.
struct ClipRange: Equatable {
    var start: Double
    var end: Double

    var length: Double { end - start }

    /// From the star at or before the playhead to the next star; without stars
    /// around, from the playhead, ten seconds long. Never past the end.
    static func suggested(position: Double, stars: [Double], duration: Double) -> ClipRange {
        let sorted = stars.sorted()
        let start = sorted.last { $0 <= position + 0.05 } ?? position
        let end = sorted.first { $0 > start + 0.05 } ?? (sorted.isEmpty ? start + 10 : duration)
        return ClipRange(start: start, end: duration > 0 ? min(end, duration) : end)
    }

    /// Why this range cannot be exported, or nil.
    func problem(duration: Double, format: ClipExporter.Format) -> String? {
        if length <= 0 { return L("结束时间要晚于开始时间") }
        if start < 0 || (duration > 0 && end > duration + 0.05) { return L("时间超出了视频长度") }
        if format == .gif && length > ClipExporter.maxGIFLength {
            return L("动图最长 %@ 秒", String(Int(ClipExporter.maxGIFLength)))
        }
        return nil
    }
}

/// Exports part of a video (2026-10-19). MPVKit's FFmpeg is decode-only apart from
/// VideoToolbox H.264 and AAC, so:
/// - video: libmpv's encode mode re-encodes any input to H.264 + AAC in MP4, which
///   every Mac, phone and chat app plays;
/// - GIF and stills: frames grabbed like thumbnails, encoded with ImageIO.
enum ClipExporter {
    enum Format: Equatable {
        case video
        case gif
        case stills(count: Int)
    }

    struct Failure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    static let maxGIFLength: Double = 20
    static let gifFPS = 10.0
    static let gifWidth = 480

    /// Writes the clip and returns the files made. For stills, `destination`
    /// without extension is the name prefix: "<prefix> 1-05.jpg".
    static func export(source: URL, range: ClipRange, format: Format, to destination: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .video: return [try encodeVideo(source: source, range: range, to: destination)]
            case .gif: return [try makeGIF(source: source, range: range, to: destination)]
            case .stills(let count): return try makeStills(source: source, range: range, count: count, prefix: destination)
            }
        }.value
    }

    // MARK: video

    private static func encodeVideo(source: URL, range: ClipRange, to out: URL) throws -> URL {
        let probe = MPVFrameGrabber.grab(source: source.path, start: "0", thumbnailTo: nil).probe
        guard let probe else { throw Failure(reason: L("无法读取这个视频")) }
        let pixels = max(probe.width * probe.height, 640 * 360)
        let bitrate = min(max(pixels * 4, 1_500_000), 24_000_000)          // ~8 Mb/s at 1080p
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(out.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try runEncoder(source: source, range: range, bitrate: bitrate, to: tmp)
        return try place(tmp, at: out)
    }

    /// The MP4 is complete once the mpv instance is destroyed (on return).
    private static func runEncoder(source: URL, range: ClipRange, bitrate: Int, to tmp: URL) throws {
        guard let h = mpv_create() else { throw Failure(reason: "mpv_create failed") }
        defer { mpv_terminate_destroy(h) }
        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("ytdl", "no"), ("hwdec", "no"), ("sid", "no"),
            ("o", tmp.path), ("of", "mp4"), ("ovc", "h264_videotoolbox"), ("ovcopts", "b=\(bitrate)"),
            ("oac", "aac"), ("oacopts", "b=160000"),
            ("start", String(range.start)), ("end", String(range.end)),
        ]
        for (k, v) in options where mpv_set_option_string(h, k, v) < 0 {
            throw Failure(reason: "option \(k)=\(v)")
        }
        mpv_request_log_messages(h, "error")
        guard mpv_initialize(h) >= 0 else { throw Failure(reason: "mpv_initialize failed") }
        var args: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")), UnsafePointer(strdup(source.path)), nil]
        defer { args.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        guard args.withUnsafeMutableBufferPointer({ mpv_command(h, $0.baseAddress) }) >= 0 else {
            throw Failure(reason: L("无法读取这个视频"))
        }

        var errors: [String] = []
        var finished = false, failed = false
        let deadline = Date().addingTimeInterval(max(60, range.length * 4))
        while Date() < deadline, !finished {
            guard let ev = mpv_wait_event(h, 0.5) else { continue }
            switch ev.pointee.event_id {
            case MPV_EVENT_END_FILE:
                let reason = ev.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                failed = reason != MPV_END_FILE_REASON_EOF
                finished = true
            case MPV_EVENT_SHUTDOWN: finished = true
            case MPV_EVENT_LOG_MESSAGE:
                if let d = ev.pointee.data {
                    errors.append(String(cString: d.assumingMemoryBound(to: mpv_event_log_message.self).pointee.text)
                        .trimmingCharacters(in: .newlines))
                }
            default: continue
            }
        }
        guard finished, !failed else {
            NSLog("clip export failed: %@", errors.joined(separator: " | "))
            throw Failure(reason: finished ? L("无法读取这个视频") : L("导出超时"))
        }
    }

    // MARK: GIF and stills

    /// Grabs frames at `times` in parallel (each with its own short-lived mpv).
    private static func frames(source: URL, at times: [Double], width: Int?) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = times.indices.map { dir.appendingPathComponent("\($0).jpg") }
        var failures = [String?](repeating: nil, count: times.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: times.count) { i in
            var failure: String?
            for _ in 0..<2 {                   // a grab under heavy load occasionally misses; retry once
                failure = MPVFrameGrabber.grab(source: source.path, start: String(times[i]), thumbnailTo: urls[i], width: width).failure
                if failure == nil { break }
            }
            lock.lock(); failures[i] = failure; lock.unlock()
        }
        if let f = failures.compactMap({ $0 }).first {
            try? FileManager.default.removeItem(at: dir)
            NSLog("clip frame grab failed: %@", f)
            throw Failure(reason: L("无法读取这个视频"))
        }
        return urls
    }

    private static func makeGIF(source: URL, range: ClipRange, to out: URL) throws -> URL {
        let count = max(1, Int((range.length * gifFPS).rounded()))
        let times = (0..<count).map { range.start + Double($0) / gifFPS }
        let jpegs = try frames(source: source, at: times, width: gifWidth)
        defer { try? FileManager.default.removeItem(at: jpegs[0].deletingLastPathComponent()) }

        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw Failure(reason: L("无法写入 %@", out.path))
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / gifFPS]] as CFDictionary
        for url in jpegs {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure(reason: L("无法读取这个视频")) }
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw Failure(reason: L("无法写入 %@", out.path)) }
        return try place(tmp, at: out)
    }

    private static func makeStills(source: URL, range: ClipRange, count: Int, prefix: URL) throws -> [URL] {
        let n = max(1, count)
        let times = n == 1 ? [range.start] : (0..<n).map { range.start + range.length * Double($0) / Double(n - 1) }
        let jpegs = try frames(source: source, at: times, width: nil)
        defer { try? FileManager.default.removeItem(at: jpegs[0].deletingLastPathComponent()) }
        let base = prefix.deletingPathExtension()
        var made: [URL] = []
        for (t, jpeg) in zip(times, jpegs) {
            let stamp = TimeFormatting.string(t).replacingOccurrences(of: ":", with: "-")
            var url = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(stamp).jpg")
            var k = 2
            while made.contains(url) {          // two stills in the same second
                url = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(stamp) (\(k)).jpg")
                k += 1
            }
            made.append(try place(jpeg, at: url))
        }
        return made
    }

    /// Moves a finished temp file into place (replacing what the save panel agreed to replace).
    private static func place(_ tmp: URL, at out: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: tmp.path),
              ((try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0) > 0 else {
            throw Failure(reason: L("无法读取这个视频"))
        }
        try? FileManager.default.removeItem(at: out)
        do { try FileManager.default.moveItem(at: tmp, to: out) } catch { throw Failure(reason: L("无法写入 %@", out.path)) }
        return out
    }
}
