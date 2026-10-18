import Foundation

/// Files can arrive through `application(_:open:)` before launch finishes and
/// again through argv. Queue them, filter non-media, and open exactly one.
struct LaunchOpenQueue {
    private(set) var hasFinishedLaunching = false
    private var pending: [URL] = []

    /// Returns the file to open now, or nil if it was queued or nothing qualifies.
    mutating func receive(_ urls: [URL]) -> URL? {
        let media = urls.filter(MediaTypes.isMedia)
        guard hasFinishedLaunching else {
            pending += media
            return nil
        }
        return media.first
    }

    /// Call once from applicationDidFinishLaunching. Returns the file to open.
    mutating func finishLaunching(commandLine: [URL]) -> URL? {
        hasFinishedLaunching = true
        // Only one window: the first file wins, so a file that arrived through
        // both AppKit and argv is still opened exactly once.
        let first = (pending + commandLine.filter(MediaTypes.isMedia)).first
        pending.removeAll()
        return first
    }
}
