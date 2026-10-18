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

/// Grabs one frame with a short-lived, separate libmpv instance: software
/// decoding, rendered through libmpv's software render API into memory, then
/// encoded to JPEG with ImageIO.
///
/// Why not the obvious routes (both found by test I11):
/// - `screenshot-to-file` on the main player fails because playback uses
///   VideoToolbox and mpv cannot convert those GPU frames.
/// - `--vo=image` fails because MPVKit's FFmpeg is decode-only (no JPEG/PNG encoder).
/// A separate instance also never disturbs playback.
final class MPVThumbnailMaker: ThumbnailMaker {
    static let width = 480
    static let timeout: Double = 15

    private static let queue = DispatchQueue(label: "io.github.johnsonlee2801-source.videotool.thumbnails", qos: .utility)
    private static let failureLock = NSLock()
    private static var _lastFailure: String?
    /// Why the last extraction failed (for logs and tests).
    static var lastFailure: String? {
        failureLock.lock(); defer { failureLock.unlock() }
        return _lastFailure
    }

    func makeThumbnail(source: String, at time: Double, to url: URL, completion: @escaping (Bool) -> Void) {
        Self.queue.async {
            let failure = Self.extract(source: source, time: time, to: url)
            Self.failureLock.lock(); Self._lastFailure = failure; Self.failureLock.unlock()
            if let failure { NSLog("thumbnail failed: %@", failure) }
            DispatchQueue.main.async { completion(failure == nil) }
        }
    }

    /// Returns nil on success, otherwise the reason.
    private static func extract(source: String, time: Double, to url: URL) -> String? {
        guard let h = mpv_create() else { return "mpv_create failed" }
        defer { mpv_terminate_destroy(h) }

        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("idle", "yes"), ("ytdl", "no"),
            ("vo", "libmpv"), ("hwdec", "no"), ("aid", "no"), ("sid", "no"), ("osd-level", "0"),
            ("pause", "yes"), ("keep-open", "yes"),
            ("start", String(format: "%.3f", max(0, time))), ("hr-seek", "yes"),
        ]
        for (k, v) in options {
            let r = mpv_set_option_string(h, k, v)
            if r < 0 { return "option \(k)=\(v): \(String(cString: mpv_error_string(r)))" }
        }
        mpv_request_log_messages(h, "warn")
        let ir = mpv_initialize(h)
        guard ir >= 0 else { return "initialize: \(String(cString: mpv_error_string(ir)))" }

        // Software render context (must be freed before mpv is destroyed).
        let apiType = strdup("sw")
        defer { free(apiType) }
        var rc: OpaquePointer?
        var createParams = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        let cr = createParams.withUnsafeMutableBufferPointer { mpv_render_context_create(&rc, h, $0.baseAddress) }
        guard cr >= 0, let rc else { return "render context: \(String(cString: mpv_error_string(cr)))" }
        defer { mpv_render_context_free(rc) }

        var args: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")), UnsafePointer(strdup(source)), nil]
        defer { args.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let lr = args.withUnsafeMutableBufferPointer { mpv_command(h, $0.baseAddress) }
        guard lr >= 0 else { return "loadfile: \(String(cString: mpv_error_string(lr)))" }

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
        guard restarted else { return "file did not load; mpv said: \(logs.joined(separator: " | "))" }

        var dw: Int64 = 0, dh: Int64 = 0
        mpv_get_property(h, "dwidth", MPV_FORMAT_INT64, &dw)
        mpv_get_property(h, "dheight", MPV_FORMAT_INT64, &dh)
        guard dw > 0, dh > 0 else { return "no video track (dwidth=\(dw), dheight=\(dh))" }

        let w = width
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
        guard rendered else { return "no frame rendered; mpv said: \(logs.joined(separator: " | "))" }
        return writeJPEG(pixels, width: w, height: height, stride: stride, to: url)
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

    private static func writeJPEG(_ pixels: [UInt8], width: Int, height: Int, stride: Int, to url: URL) -> String? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return "could not build CGImage" }
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return "could not create \(url.path)"
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? nil : "JPEG encoding failed"
    }
}
