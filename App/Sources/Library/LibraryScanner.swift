import Foundation

struct ScannedFile: Equatable {
    var path: String
    var size: Int64
    var modified: Date
    /// An iCloud file whose content is not on this Mac. Reading it would force a download.
    var cloudOnly = false
}

struct ScanResult: Equatable {
    var files: [ScannedFile]
    /// False when the root is missing or not a folder, or part of the tree could not be read.
    /// Callers must not treat files missing from an incomplete scan as deleted.
    var complete: Bool
}

/// Lists the videos under a folder. Read-only: it never changes anything on disk.
enum LibraryScanner {
    /// Recursive, skipping hidden items and packages (.app, .photoslibrary…) and
    /// not following symbolic links. Audio files are not part of the video library.
    /// Paths keep the root exactly as given. Sorted by path.
    static func scan(root: String, isCancelled: () -> Bool = { false }) -> ScanResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return ScanResult(files: [], complete: false)
        }
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var hadError = false
        guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                          errorHandler: { _, _ in hadError = true; return true })
        else { return ScanResult(files: [], complete: false) }

        let videos = Set(MediaTypes.videoExtensions)
        // The enumerator may spell paths differently from `root` (e.g. /var vs
        // /private/var). Rebuild every path under the root as given, so folder
        // grouping and the stored paths stay consistent.
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        let base = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        var out: [ScannedFile] = []
        var cancelled = false
        for case let url as URL in walker {
            if isCancelled() { cancelled = true; break }
            guard videos.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true
            else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            let path = resolved.hasPrefix(resolvedRoot + "/") ? base + resolved.dropFirst(resolvedRoot.count) : url.path
            let cloudOnly = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
            out.append(ScannedFile(path: path, size: Int64(values.fileSize ?? 0),
                                   modified: values.contentModificationDate ?? .distantPast, cloudOnly: cloudOnly))
        }
        return ScanResult(files: out.sorted { $0.path < $1.path }, complete: !hadError && !cancelled)
    }
}
