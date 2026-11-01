import Foundation

/// One shallow directory snapshot. Enumeration never runs on the UI thread.
struct FolderDirectory {
    var folders: [String]
    var videos: [String]

    static func sorted(_ paths: [String]) -> [String] {
        Array(Set(paths)).sorted {
            let a = ($0 as NSString).lastPathComponent, b = ($1 as NSString).lastPathComponent
            let order = a.localizedStandardCompare(b)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }

    static func read(_ path: String) throws -> FolderDirectory {
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        var folders: [String] = [], videos: [String] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            // Foundation can canonicalize /var into /private/var during a read.
            // Preserve the caller's spelling so selection and currentPath match.
            let child = (path as NSString).appendingPathComponent(url.lastPathComponent)
            if values.isDirectory == true { folders.append(child) }
            else if values.isRegularFile == true && MediaTypes.isMedia(url) { videos.append(child) }
        }
        return FolderDirectory(folders: sorted(folders), videos: sorted(videos))
    }
}

/// Each owner has its own loader; invalidation prevents stale UI and playback targets.
final class FolderDirectoryLoader {
    typealias Executor = (@escaping () -> Void) -> Void
    private let read: (String) throws -> FolderDirectory
    private let background: Executor
    private let main: Executor
    private var generation = 0

    init(read: @escaping (String) throws -> FolderDirectory = FolderDirectory.read,
         background: @escaping Executor = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) }) {
        self.read = read; self.background = background; self.main = main
    }
    func cancel() { generation += 1 }
    func load(_ path: String, completion: @escaping (Result<FolderDirectory, Error>) -> Void) {
        generation += 1
        let request = generation, read = self.read, main = self.main
        background { [weak self] in
            let result = Result { try read(path) }
            main { [weak self] in
                guard let self, self.generation == request else { return }
                completion(result)
            }
        }
    }
}

/// Navigation is independent of library filters. Loading a queue never opens a file.
final class FolderPlaybackQueue {
    private let loader: FolderDirectoryLoader
    private(set) var previous: String?
    private(set) var next: String?
    private(set) var error: Error?
    var onChange: (() -> Void)?
    init(read: @escaping (String) throws -> FolderDirectory = FolderDirectory.read,
         background: @escaping FolderDirectoryLoader.Executor = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping FolderDirectoryLoader.Executor = { DispatchQueue.main.async(execute: $0) }) {
        loader = FolderDirectoryLoader(read: read, background: background, main: main)
    }
    func load(_ path: String?) {
        loader.cancel(); previous = nil; next = nil; error = nil; onChange?()
        guard let path else { return }
        let folder = (path as NSString).deletingLastPathComponent
        loader.load(folder) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                let paths = FolderDirectory.sorted(snapshot.videos.filter { ($0 as NSString).deletingLastPathComponent == folder })
                if let i = paths.firstIndex(of: path) {
                    self.previous = i > 0 ? paths[i - 1] : nil
                    self.next = i + 1 < paths.count ? paths[i + 1] : nil
                }
            case .failure(let error): self.error = error
            }
            self.onChange?()
        }
    }
    func shutdown() { loader.cancel(); previous = nil; next = nil; onChange = nil }
}
