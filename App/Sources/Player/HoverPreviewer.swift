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
    /// Frames kept per file (about 200 small JPEG-sized images).
    static let cacheLimit = 200

    private let grab: Grab
    private let schedule: Schedule
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    private var source: String?
    private var cache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private var generation = 0
    /// Bumped by every setSource: a grab started for an earlier opening is never cached.
    private var revision = 0
    /// The newest request, readable from the grab queue: queued grabs that are no longer
    /// wanted are skipped instead of decoding behind each other (audit 2026-10-20).
    private let latest = LatestRequest()

    private final class LatestRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func isCurrent(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == v }
    }

    var cachedCount: Int { cache.count }

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
        cacheOrder.removeAll()
        generation += 1
        revision += 1
        latest.set(generation)
    }

    /// The cached frame for `time`, or nil; then `ready` gets it on the main queue when grabbed.
    func request(_ time: Double, ready: @escaping (NSImage) -> Void) -> NSImage? {
        let key = Int((max(time, 0) / Self.step).rounded(.down))
        if let image = cache[key] { return image }
        generation += 1
        let wanted = generation
        latest.set(wanted)
        schedule(Self.pause) { [weak self] in
            guard let self, wanted == self.generation, let source = self.source else { return }
            let at = Double(key) * Self.step
            let revision = self.revision
            self.background { [grab, main, latest] in
                guard latest.isCurrent(wanted) else { return }
                let image = grab(source, at)
                main { [weak self] in
                    guard let self, let image, self.revision == revision else { return }
                    self.store(image, at: key)
                    if wanted == self.generation { ready(image) }
                }
            }
        }
        return nil
    }

    private func store(_ image: NSImage, at key: Int) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = image
        while cacheOrder.count > Self.cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// A small frame from a separate libmpv instance (keyframe seek: fast enough for hovering).
    nonisolated static func mpvGrab(source: String, time: Double) -> NSImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = MPVFrameGrabber.grab(source: source, start: String(format: "%.2f", time), thumbnailTo: url, precise: false)
        return NSImage(contentsOf: url)
    }
}
