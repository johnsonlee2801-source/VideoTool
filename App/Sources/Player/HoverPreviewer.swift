import AppKit

/// Thumbnails for hovering the progress bar. A short pause before grabbing, only
/// the latest request is rendered (moving fast never builds a queue), and frames
/// already seen are kept per 2-second step until another file is opened.
@MainActor
final class HoverPreviewer {
    typealias Grab = (_ source: String, _ time: Double) -> NSImage?
    typealias Schedule = (_ after: Double, _ run: @escaping () -> Void) -> Void

    static let step = 2.0
    static let pause = 0.12

    private let grab: Grab
    private let schedule: Schedule
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    private var source: String?
    private var cache: [Int: NSImage] = [:]
    private var generation = 0

    init(grab: @escaping Grab = HoverPreviewer.mpvGrab,
         schedule: @escaping Schedule = { after, run in DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: run) },
         background: @escaping (@escaping () -> Void) -> Void = { HoverPreviewer.queue.async(execute: $0) },
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.grab = grab
        self.schedule = schedule
        self.background = background
        self.main = main
    }

    private static let queue = DispatchQueue(label: "io.github.johnsonlee2801-source.videotool.hover", qos: .userInitiated)

    func setSource(_ path: String?) {
        source = path
        cache.removeAll()
        generation += 1
    }

    /// The cached frame for `time`, or nil; then `ready` gets it on the main queue when grabbed.
    func request(_ time: Double, ready: @escaping (NSImage) -> Void) -> NSImage? {
        let key = Int((max(time, 0) / Self.step).rounded(.down))
        if let image = cache[key] { return image }
        generation += 1
        let wanted = generation
        schedule(Self.pause) { [weak self] in
            guard let self, wanted == self.generation, let source = self.source else { return }
            let at = Double(key) * Self.step
            self.background { [grab, main] in
                let image = grab(source, at)
                main { [weak self] in
                    guard let self, let image, self.source == source else { return }
                    self.cache[key] = image
                    if wanted == self.generation { ready(image) }
                }
            }
        }
        return nil
    }

    /// A small frame from a separate libmpv instance (keyframe seek: fast enough for hovering).
    nonisolated static func mpvGrab(source: String, time: Double) -> NSImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = MPVFrameGrabber.grab(source: source, start: String(format: "%.2f", time), thumbnailTo: url, precise: false)
        return NSImage(contentsOf: url)
    }
}
