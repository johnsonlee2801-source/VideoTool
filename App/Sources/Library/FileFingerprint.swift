import CryptoKit
import Foundation

/// Identifies a video by content so stars survive renames and moves.
///
/// Files of 128 KB or more use the OpenSubtitles hash (OSHash): file size plus
/// the wrapping 64-bit sum of the first and last 64 KB read as little-endian
/// UInt64s. It reads 128 KB whatever the file size, and VLC, Kodi and Plex use
/// the same algorithm. Smaller files use SHA-256 of the whole content.
/// Keys are prefixed (`osh:`, `sha:`, `url:`) so the scheme can evolve.
enum FileFingerprint {
    static let chunkSize = 65_536

    enum Failure: Error { case unreadable(String) }

    static func compute(path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure.unreadable(path) }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        if size < UInt64(chunkSize * 2) {
            let data = try handle.readToEnd() ?? Data()
            return "sha:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        var hash = size
        for offset in [UInt64(0), size - UInt64(chunkSize)] {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: chunkSize), chunk.count == chunkSize else {
                throw Failure.unreadable(path)
            }
            chunk.withUnsafeBytes { raw in
                for i in stride(from: 0, to: chunkSize, by: 8) {
                    hash &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                }
            }
        }
        return "osh:" + String(format: "%016llx", hash)
    }

    /// Key for whatever mpv was asked to play: local files by content, anything
    /// that is not an existing local path by its URL string.
    static func key(forTarget target: String) -> String? {
        if target.hasPrefix("/") {
            return try? compute(path: target)
        }
        if let url = URL(string: target), url.isFileURL {
            return try? compute(path: url.path)
        }
        return "url:" + target
    }
}
