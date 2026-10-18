import Foundation
import UniformTypeIdentifiers

/// Single source of truth for what the app claims to open. A test asserts the
/// generated Info.plist covers every extension listed here.
enum MediaTypes {
    static let videoExtensions: [String] = [
        "3g2", "3gp", "amv", "asf", "avi", "divx", "dv", "f4v", "flv", "m2ts", "m2v", "m4v",
        "mk3d", "mkv", "mov", "mp4", "mpe", "mpeg", "mpg", "mts", "mxf", "ogm", "ogv", "qt",
        "rm", "rmvb", "ts", "vob", "webm", "wmv", "xvid", "yuv",
    ]

    static let audioExtensions: [String] = [
        "aac", "ac3", "aif", "aiff", "ape", "caf", "dts", "eac3", "flac", "m4a", "m4b", "mka",
        "mp3", "oga", "ogg", "opus", "wav", "wma", "wv",
    ]

    static var allExtensions: [String] { videoExtensions + audioExtensions }

    static func isMedia(_ url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }

    /// Types for the open panel and for "set as default". Known system types
    /// first, then whatever the system maps our extensions to.
    static var utTypes: [UTType] {
        var seen = Set<String>()
        var result: [UTType] = []
        let known: [UTType] = [.movie, .video, .audiovisualContent, .quickTimeMovie, .mpeg4Movie, .avi,
                               .mpeg, .mpeg2Video, .audio, .mp3, .wav, .aiff, .mpeg4Audio]
        for t in known + allExtensions.compactMap({ UTType(filenameExtension: $0) }) {
            if seen.insert(t.identifier).inserted { result.append(t) }
        }
        return result
    }
}
