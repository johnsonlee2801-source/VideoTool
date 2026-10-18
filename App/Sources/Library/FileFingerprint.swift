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

    static let checkSample = 262_144

    /// Confirms that files sharing an OSHash really have the same content: SHA-256
    /// over the size and 256 KB samples at 25 %, 50 % and 75 % (OSHash only looks
    /// at the first and last 64 KB). Small files hash everything. Reads at most 768 KB.
    static func contentCheck(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var hasher = SHA256()
        hasher.update(data: withUnsafeBytes(of: size.littleEndian) { Data($0) })
        if size <= UInt64(checkSample * 3) {
            try? handle.seek(toOffset: 0)
            hasher.update(data: (try? handle.readToEnd()) ?? Data())
        } else {
            for fraction in [0.25, 0.5, 0.75] {
                try? handle.seek(toOffset: UInt64(Double(size) * fraction))
                hasher.update(data: (try? handle.read(upToCount: checkSample)) ?? Data())
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
