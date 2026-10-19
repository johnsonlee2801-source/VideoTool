import CoreGraphics
import Foundation
import ImageIO
import Libmpv
import UniformTypeIdentifiers

/// Produces a still image of a video at a given time.
protocol ThumbnailMaker {
    /// `completion` runs on the main queue with true if `url` now holds a JPEG.
    func makeThumbnail(source: String, at time: Double, to url: URL, completion: @escaping (Bool) -> Void)
}

struct MediaProbe: Equatable {
    var duration: Double
    var width: Int
    var height: Int
}

/// Reads a video's duration and size and (optionally) writes a thumbnail.
/// Synchronous: call it from a background queue.
protocol MediaProber {
    func probe(source: String, thumbnailTo url: URL?) -> MediaProbe?
}

/// Grabs one frame with a short-lived, separate libmpv instance: software
/// decoding, rendered through libmpv's software render API into memory, then
/// encoded to JPEG with ImageIO.
///
/// Why not the obvious routes (both found by test I11):
/// - `screenshot-to-file` on the main player fails because playback uses
///   VideoToolbox and mpv cannot convert those GPU frames.
/// - `--vo=image` fails because MPVKit's FFmpeg is decode-only (no JPEG/PNG encoder).
/// A separate instance also never disturbs playback.
enum MPVFrameGrabber {
    static let width = 480
    static let timeout: Double = 15

    /// `start` is anything mpv's `--start` accepts ("12.5", "10%").
    /// Returns the probe (nil if the file could not be opened) and, if a
    /// thumbnail was requested but not written, the reason.
    /// `subtitles`: an external subtitle file drawn into the frame (checks of what the player shows).
    /// `precise: false` lands on the nearest keyframe (hover previews: speed over accuracy).
    /// `width`: of the image; nil keeps the video's own width.
    static func grab(source: String, start: String, thumbnailTo url: URL?,
                     subtitles: String? = nil, precise: Bool = true,
                     width: Int? = MPVFrameGrabber.width) -> (probe: MediaProbe?, failure: String?) {
        guard let h = mpv_create() else { return (nil, "mpv_create failed") }
        defer { mpv_terminate_destroy(h) }

        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("idle", "yes"), ("ytdl", "no"),
            // Keep the audio track (audio-only files have nothing else to load) but never
            // open a sound device: ao=null. Found by FormatMatrixTests FM3.
            ("vo", "libmpv"), ("hwdec", "no"), ("ao", "null"), ("sid", "no"), ("osd-level", "0"),
            ("pause", "yes"), ("keep-open", "yes"), ("start", start), ("hr-seek", precise ? "yes" : "no"),
            // The software renderer asserts (and aborts the whole process) on rotated video
            // (mp_image_crop, found by FormatMatrixTests with a phone-style 90° flag).
            // Render unrotated and rotate the bitmap ourselves.
            ("video-rotate", "no"),
        ] + (subtitles.map { [("sid", "auto"), ("sub-files", $0)] } ?? [])
        for (k, v) in options {
            let r = mpv_set_option_string(h, k, v)
            if r < 0 { return (nil, "option \(k)=\(v): \(String(cString: mpv_error_string(r)))") }
        }
        mpv_request_log_messages(h, "warn")
        let ir = mpv_initialize(h)
        guard ir >= 0 else { return (nil, "initialize: \(String(cString: mpv_error_string(ir)))") }

        // Software render context (must be freed before mpv is destroyed).
        let apiType = strdup("sw")
        defer { free(apiType) }
        var rc: OpaquePointer?
        var createParams = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        let cr = createParams.withUnsafeMutableBufferPointer { mpv_render_context_create(&rc, h, $0.baseAddress) }
        guard cr >= 0, let rc else { return (nil, "render context: \(String(cString: mpv_error_string(cr)))") }
        defer { mpv_render_context_free(rc) }

        var args: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")), UnsafePointer(strdup(source)), nil]
        defer { args.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let lr = args.withUnsafeMutableBufferPointer { mpv_command(h, $0.baseAddress) }
        guard lr >= 0 else { return (nil, "loadfile: \(String(cString: mpv_error_string(lr)))") }

        // Wait until the file is loaded and the initial seek has finished.
        var logs: [String] = []
        var restarted = false
        let deadline = Date().addingTimeInterval(timeout)
        waitLoop: while Date() < deadline {
            guard let ev = mpv_wait_event(h, 0.25) else { continue }
            switch ev.pointee.event_id {
            case MPV_EVENT_PLAYBACK_RESTART: restarted = true; break waitLoop
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN: break waitLoop
            case MPV_EVENT_LOG_MESSAGE:
                if let d = ev.pointee.data {
                    let m = d.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    logs.append("[\(String(cString: m.prefix))] \(String(cString: m.text))".trimmingCharacters(in: .newlines))
                }
            default: continue
            }
        }
        guard restarted else { return (nil, "file did not load; mpv said: \(logs.joined(separator: " | "))") }

        var duration = 0.0
        if mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, &duration) < 0 { duration = 0 }
        var dw: Int64 = 0, dh: Int64 = 0
        mpv_get_property(h, "dwidth", MPV_FORMAT_INT64, &dw)
        mpv_get_property(h, "dheight", MPV_FORMAT_INT64, &dh)
        // With video-rotate=no mpv zeroes video-params/rotate; the container's flag is
        // still on the track as demux-rotation.
        var rotate: Int64 = 0
        if mpv_get_property(h, "current-tracks/video/demux-rotation", MPV_FORMAT_INT64, &rotate) < 0 { rotate = 0 }
        let quarterTurn = (rotate % 180 + 180) % 180 == 90
        // Report the size as displayed (rotation applied), like the player shows it.
        let probe = MediaProbe(duration: duration, width: Int(quarterTurn ? dh : dw), height: Int(quarterTurn ? dw : dh))

        guard let url else { return (probe, nil) }
        guard dw > 0, dh > 0 else { return (probe, "no video track (dwidth=\(dw), dheight=\(dh))") }

        let w = max(2, (width ?? Int(dw)) / 2 * 2)
        let height = max(2, Int((Double(w) * Double(dh) / Double(dw)).rounded() / 2) * 2)
        let stride = w * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)

        // The frame is ready once mpv flags a new frame; poll briefly for it.
        var rendered = false
        while Date() < deadline {
            if mpv_render_context_update(rc) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                rendered = render(rc, into: &pixels, width: w, height: height, stride: stride)
                if rendered { break }
            }
            _ = mpv_wait_event(h, 0.05)
        }
        guard rendered else { return (probe, "no frame rendered; mpv said: \(logs.joined(separator: " | "))") }
        return (probe, writeJPEG(pixels, width: w, height: height, stride: stride, rotate: Int(rotate), to: url))
    }

    private static func render(_ rc: OpaquePointer, into pixels: inout [UInt8], width: Int, height: Int, stride: Int) -> Bool {
        var size: [Int32] = [Int32(width), Int32(height)]
        var stride = stride
        let format = strdup("rgb0")
        defer { free(format) }
        return pixels.withUnsafeMutableBytes { buf -> Bool in
            size.withUnsafeMutableBufferPointer { sizePtr in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buf.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return params.withUnsafeMutableBufferPointer { mpv_render_context_render(rc, $0.baseAddress) } >= 0
                }
            }
        }
    }

    /// Rotates `image` clockwise by `degrees` (0/90/180/270), as mpv's video-rotate would.
    static func rotated(_ image: CGImage, clockwise degrees: Int) -> CGImage? {
        let turns = ((degrees % 360) + 360) % 360 / 90
        guard turns != 0 else { return image }
        let swap = turns % 2 == 1
        let (w, h) = swap ? (image.height, image.width) : (image.width, image.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)          // CoreGraphics is counter-clockwise
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    private static func writeJPEG(_ pixels: [UInt8], width: Int, height: Int, stride: Int, rotate: Int, to url: URL) -> String? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let raw = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let image = rotated(raw, clockwise: rotate)
        else { return "could not build CGImage" }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return "could not create \(url.path)"
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? nil : "JPEG encoding failed"
    }
}

/// Star thumbnails: the frame at the star's time, made on a background queue.
final class MPVThumbnailMaker: ThumbnailMaker {
    static var width: Int { MPVFrameGrabber.width }

    private static let queue = DispatchQueue(label: "io.github.johnsonlee2801-source.videotool.thumbnails", qos: .utility)
    private static let failureLock = NSLock()
    private static var _lastFailure: String?
    /// Why the last extraction failed (for logs and tests).
    static var lastFailure: String? {
        failureLock.lock(); defer { failureLock.unlock() }
        return _lastFailure
    }
    fileprivate static func record(_ failure: String?) {
        failureLock.lock(); _lastFailure = failure; failureLock.unlock()
        if let failure { NSLog("thumbnail failed: %@", failure) }
    }

    func makeThumbnail(source: String, at time: Double, to url: URL, completion: @escaping (Bool) -> Void) {
        Self.queue.async {
            let result = MPVFrameGrabber.grab(source: source, start: String(format: "%.3f", max(0, time)), thumbnailTo: url)
            let failure = result.probe == nil ? (result.failure ?? "open failed") : result.failure
            Self.record(failure)
            DispatchQueue.main.async { completion(failure == nil) }
        }
    }
}

/// Library probing: duration and size, plus a thumbnail from 10% into the video
/// (skips black intros better than the first frame).
final class MPVMediaProber: MediaProber {
    func probe(source: String, thumbnailTo url: URL?) -> MediaProbe? {
        let result = MPVFrameGrabber.grab(source: source, start: "10%", thumbnailTo: url)
        if let failure = result.failure { MPVThumbnailMaker.record(failure) }
        return result.probe
    }
}
