import Foundation

/// The clip being marked with C: the first press sets one end, the second the other
/// (either order). B stays for stars; C is for cutting (2026-10-20).
struct ClipSelection: Equatable {
    enum Step: Equatable {
        case started(Double)
        case completed(ClipRange)
        case tooShort                 // the second C at the same moment: not a clip
    }

    /// Shorter than this is a double press, not a clip.
    static let minLength = 0.5

    private(set) var start: Double?
    private(set) var end: Double?

    var range: ClipRange? {
        guard let start, let end else { return nil }
        return ClipRange(start: min(start, end), end: max(start, end))
    }

    mutating func mark(_ time: Double) -> Step {
        guard let start, end == nil else {                 // nothing yet, or a finished clip: start anew
            self.start = time
            end = nil
            return .started(time)
        }
        guard abs(time - start) >= Self.minLength else { return .tooShort }
        end = time
        return .completed(range!)
    }

    mutating func clear() { start = nil; end = nil }
}

/// Where quick exports go and what they are called: "Talk 1-05–2-06.gif".
enum ClipNaming {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoTool", isDirectory: true)
    }

    /// Copied clips: VideoTool's own folder (not the shared temp folder), cleaned daily.
    static var copyDirectory: URL { AppData.directory.appendingPathComponent("Copied clips", isDirectory: true) }

    /// Deletes files in `dir` last changed more than `age` seconds ago.
    static func cleanUp(_ dir: URL, olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let url = dir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
        }
    }

    /// Longest file name made (bytes): file names stop at 255, and the exporter's
    /// temporary name adds a UUID prefix (audit 2026-10-20).
    static let maxNameBytes = 200

    /// A name that is not taken yet in `dir` (a quick export never replaces anything).
    static func freeURL(in dir: URL, video: String, range: ClipRange, ext: String) -> URL {
        let (a, b) = range.fieldTexts
        // Room for " 1-05–2-05 (99).gif": shorten the video's name, never the times.
        let tail = " \(a)–\(b)".replacingOccurrences(of: ":", with: "-")
        var title = (video as NSString).deletingPathExtension.replacingOccurrences(of: ":", with: "-")
        while !title.isEmpty && (title + tail + " (99)." + ext).utf8.count > maxNameBytes { title.removeLast() }
        let stem = title + tail
        var url = dir.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
