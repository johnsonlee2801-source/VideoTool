import Foundation

protocol NetworkVideoResolving: AnyObject {
    func resolve(_ video: NetworkVideo, completion: @escaping (Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void)
    func cancel()
}

protocol NetworkVideoProcessRunning: AnyObject {
    func run(executable: URL, arguments: [String], completion: @escaping (Result<Data, NetworkVideoFailure>) -> Void)
    func cancel()
}

/// One bounded subprocess, with no shell, stdin, inherited configuration or logs.
/// Cancellation only terminates the process created by this object.
final class NetworkVideoProcess: NetworkVideoProcessRunning {
    private let lock = NSLock()
    private var process: Process?
    private var failure: NetworkVideoFailure?
    private var diagnosticFailure: NetworkVideoFailure = .failed
    private let timeout: Double
    private let maxBytes: Int
    init(timeout: Double = 45, maxBytes: Int = 4 * 1024 * 1024) {
        self.timeout = timeout; self.maxBytes = maxBytes
    }

    func cancel() { stop(.cancelled) }
    private func stop(_ error: NetworkVideoFailure) {
        lock.lock()
        if failure == nil { failure = error }
        let child = process
        if child?.isRunning == true { child?.terminate() }
        lock.unlock()
        // An unresponsive resolver must not keep a cancelled request alive.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self, weak child] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if let child, self.process === child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    func run(executable: URL, arguments: [String], completion: @escaping (Result<Data, NetworkVideoFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let child = Process(), pipe = Pipe(), errors = Pipe(), diagnostics = DispatchGroup()
            child.executableURL = executable
            child.arguments = arguments
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = pipe
            child.standardError = errors
            diagnostics.enter()
            DispatchQueue.global(qos: .utility).async {
                var tail = ""
                while let bytes = try? errors.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {
                    let text = tail + String(decoding: bytes, as: UTF8.self)
                    let category = NetworkVideoFailure.classify(text)
                    self.lock.lock()
                    if category != .failed { self.diagnosticFailure = category }
                    self.lock.unlock()
                    tail = String(text.suffix(256))
                }
                try? errors.fileHandleForReading.close()
                diagnostics.leave()
            }
            child.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            child.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.lock.lock()
            self.process = child
            do {
                if self.failure == nil { try child.run() }
            } catch { self.failure = .failed }
            let started = child.isRunning || (self.failure == nil)
            self.lock.unlock()
            // Close the parent's writer even if spawn failed, so the diagnostic
            // reader always reaches EOF. The child has its own duplicated handle.
            try? errors.fileHandleForWriting.close()
            var data = Data()
            let deadline = DispatchWorkItem { [weak self] in self?.stop(.timeout) }
            if started {
                DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout, execute: deadline)
                // Read while it runs so large JSON cannot fill the pipe and deadlock.
                while let bytes = try? pipe.fileHandleForReading.read(upToCount: 16384), !bytes.isEmpty {
                    if data.count + bytes.count > self.maxBytes { self.stop(.invalidResponse); break }
                    data.append(bytes)
                }
                try? pipe.fileHandleForReading.close()
                child.waitUntilExit()
            }
            deadline.cancel()
            _ = diagnostics.wait(timeout: .now() + 1)
            self.lock.lock()
            let failure = self.failure
            let diagnosticFailure = self.diagnosticFailure
            self.process = nil
            self.lock.unlock()
            let result: Result<Data, NetworkVideoFailure>
            if let failure { result = .failure(failure) }
            else if child.terminationStatus != 0 { result = .failure(diagnosticFailure) }
            else { result = .success(data) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Main-thread coordinator. Tokens also protect against a cancelled process
/// delivering its result after another local/network open or window close.
final class NetworkVideoResolver: NetworkVideoResolving {
    typealias Tools = (executable: URL, deno: String)
    private let tools: () -> Tools?
    private let makeProcess: () -> NetworkVideoProcessRunning
    private var process: NetworkVideoProcessRunning?
    private var generation = 0
    private let catalog: BilibiliCatalogFetching

    init(tools: @escaping () -> Tools? = NetworkVideoResolver.installedTools,
         makeProcess: @escaping () -> NetworkVideoProcessRunning = { NetworkVideoProcess() },
         catalog: BilibiliCatalogFetching = BilibiliCatalogFetcher()) {
        self.tools = tools; self.makeProcess = makeProcess; self.catalog = catalog
    }

    static func installedTools() -> Tools? {
        let roots = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path, "/opt/homebrew/bin", "/usr/local/bin"]
        func executable(_ name: String) -> String? {
            roots.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        guard let yt = executable("yt-dlp") else { return nil }
        return (URL(fileURLWithPath: yt), executable("deno") ?? "")
    }

    static func arguments(for video: NetworkVideo, deno: String) -> [String] {
        let base = ["--ignore-config", "--no-cache-dir", "--no-plugin-dirs", "--no-remote-components",
         "--no-playlist", "--skip-download", "--dump-single-json", "--no-progress",
         "--socket-timeout", "10", "--retries", "1", "--extractor-retries", "1",
         "--no-js-runtimes",
         "--format", "bestvideo[height<=1080]+bestaudio/best[height<=1080]",
         "--", video.url.absoluteString]
        return video.site == .youtube ? Array(base.dropLast(2)) + ["--js-runtimes", "deno:" + deno] + Array(base.suffix(2)) : base
    }

    func resolve(_ video: NetworkVideo, completion: @escaping (Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void) {
        cancel()
        guard let tools = tools() else { completion(.failure(.missingTools)); return }
        guard video.site != .youtube || !tools.deno.isEmpty else { completion(.failure(.missingDeno)); return }
        let token = generation
        func extract(_ request: NetworkVideo, parts: [BilibiliPart]) {
            guard self.generation == token else { return }
            let process = self.makeProcess(); self.process = process
            process.run(executable: tools.executable, arguments: Self.arguments(for: request, deno: tools.deno)) { [weak self] result in
                guard let self, self.generation == token else { return }
                self.process = nil
                switch result {
                case .success(let data):
                    do {
                        var media = try ResolvedNetworkVideo.decode(data: data, request: request)
                        media.parts = parts
                        completion(.success(media))
                    } catch { completion(.failure(error as? NetworkVideoFailure ?? .invalidResponse)) }
                case .failure(let error): completion(.failure(error))
                }
            }
        }
        if video.site == .youtube { extract(video, parts: []) }
        else {
            catalog.fetch(video) { [weak self] result in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let value): extract(value.request, parts: value.parts)
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }

    func cancel() { generation += 1; catalog.cancel(); process?.cancel(); process = nil }
    deinit { catalog.cancel(); process?.cancel() }
}
