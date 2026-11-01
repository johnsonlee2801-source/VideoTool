import Foundation

enum SubtitleInput: Equatable {
    case file(URL, bilingual: Bool)
    case embedded(URL, stream: Int)
    case website(NetworkCaptionTrack)
}
struct SubtitleSourceOption: Equatable {
    let id: String
    let title: String
    let input: SubtitleInput
    var playerTrackID: String? = nil
}
protocol SubtitleContentLoading: AnyObject {
    func localSources(_ video: URL, completion: @escaping (Result<[SubtitleSourceOption], SubtitleLoadFailure>) -> Void)
    func load(_ input: SubtitleInput, completion: @escaping (Result<SubtitleTranscript, SubtitleLoadFailure>) -> Void)
    func cancel()
}

final class SubtitleContentLoader: SubtitleContentLoading {
    private let ffmpeg: () -> URL?
    private let ffprobe: () -> URL?
    private let makeProcess: () -> NetworkVideoProcessRunning
    private var process: NetworkVideoProcessRunning?
    private var transfer: CaptionTransfer?
    private var generation = 0
    init(ffmpeg: @escaping () -> URL? = { SubtitleContentLoader.tool("ffmpeg") }, ffprobe: @escaping () -> URL? = { SubtitleContentLoader.tool("ffprobe") },
         makeProcess: @escaping () -> NetworkVideoProcessRunning = { NetworkVideoProcess() }) {
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.makeProcess = makeProcess
    }
    static func tool(_ name: String) -> URL? {
        [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path, "/opt/homebrew/bin", "/usr/local/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static func localURL(_ url: URL, video: Bool) -> URL? {
        guard url.isFileURL, url.host == nil || url.host == "localhost" else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard video ? MediaTypes.isMedia(resolved) : ["srt", "vtt", "ass", "ssa"].contains(resolved.pathExtension.lowercased()) else { return nil }
        return resolved
    }
    func localSources(_ video: URL, completion: @escaping (Result<[SubtitleSourceOption], SubtitleLoadFailure>) -> Void) {
        cancel()
        guard let video = Self.localURL(video, video: true) else { completion(.failure(.unavailable)); return }
        guard let executable = ffprobe() else { completion(.failure(.missingFFmpeg)); return }
        let token = generation, process = makeProcess(); self.process = process
        let args = ["-v", "error", "-protocol_whitelist", "file,pipe", "-select_streams", "s", "-show_entries", "stream=index:stream_tags=language,title", "-of", "json", "-i", video.path]
        process.run(executable: executable, arguments: args) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.process = nil
            guard case .success(let data) = result,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let streams = root["streams"] as? [[String: Any]], streams.count <= 256 else { completion(.failure(.unavailable)); return }
            let options = streams.enumerated().compactMap { ordinal, row -> SubtitleSourceOption? in
                guard let index = row["index"] as? Int, (0..<1024).contains(index) else { return nil }
                let tags = row["tags"] as? [String: String] ?? [:]
                let text = [tags["language"], tags["title"]].compactMap { $0 }.joined(separator: " · ")
                let clean = String(String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(200))
                let title = L("内嵌字幕 %@", String(ordinal + 1)) + (clean.isEmpty ? "" : " · " + clean)
                return SubtitleSourceOption(id: "embedded:\(index)", title: title, input: .embedded(video, stream: index))
            }
            completion(.success(options))
        }
    }
    func load(_ input: SubtitleInput, completion: @escaping (Result<SubtitleTranscript, SubtitleLoadFailure>) -> Void) {
        cancel()
        let token = generation
        func decode(_ data: Data, format: String, bilingual: Bool = false) {
            self.decode(data, format: format, bilingual: bilingual, token: token, completion: completion)
        }
        switch input {
        case .website(let track):
            if let inline = track.inline { decode(Data(inline.utf8), format: track.format); return }
            transfer = CaptionTransfer(track: track) { [weak self] result in
                guard let self, self.generation == token else { return }
                self.transfer = nil
                switch result { case .success(let data): decode(data, format: track.format); case .failure(let error): completion(.failure(error)) }
            }
            transfer?.start()
        case .file(let input, let bilingual):
            guard let url = Self.localURL(input, video: false) else { completion(.failure(.unavailable)); return }
            let format = url.pathExtension.lowercased()
            if format == "srt" || format == "vtt" {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { () throws -> Data in
                        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                        var data = Data()
                        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                            guard data.count + bytes.count <= SubtitleTranscript.maxBytes else { throw SubtitleLoadFailure.tooLarge }
                            data.append(bytes)
                        }
                        return data
                    }
                    DispatchQueue.main.async {
                        guard self.generation == token else { return }
                        switch result { case .success(let data): decode(data, format: format, bilingual: bilingual); case .failure(let error): completion(.failure(error as? SubtitleLoadFailure ?? .unavailable)) }
                    }
                }
            } else { convert(url, stream: nil, token: token, completion: completion) }
        case .embedded(let input, let stream):
            guard let url = Self.localURL(input, video: true), (0..<1024).contains(stream) else { completion(.failure(.unavailable)); return }
            convert(url, stream: stream, token: token, completion: completion)
        }
    }
    private func convert(_ url: URL, stream: Int?, token: Int, completion: @escaping (Result<SubtitleTranscript, SubtitleLoadFailure>) -> Void) {
        guard let executable = ffmpeg() else { completion(.failure(.missingFFmpeg)); return }
        var args = ["-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", url.path]
        if let stream { args += ["-map", "0:\(stream)"] }
        args += ["-f", "srt", "pipe:1"]
        let process = makeProcess(); self.process = process
        process.run(executable: executable, arguments: args) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.process = nil
            switch result {
            case .success(let data): self.decode(data, format: "srt", token: token, completion: completion)
            case .failure(let error): completion(.failure(error == .timeout ? .timeout : .unavailable))
            }
        }
    }
    /// Parsing, normalization and search-key preparation stay off the playback UI.
    private func decode(_ data: Data, format: String, bilingual: Bool = false, token: Int,
                        completion: @escaping (Result<SubtitleTranscript, SubtitleLoadFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> SubtitleTranscript in
                let document = try SubtitleTranscript.decode(data, format: format, bilingual: bilingual)
                guard !document.cues.isEmpty else { throw SubtitleLoadFailure.unavailable }
                return document
            }.mapError { $0 as? SubtitleLoadFailure ?? .invalidText }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                completion(result)
            }
        }
    }
    func cancel() { generation += 1; process?.cancel(); process = nil; transfer?.cancel(); transfer = nil }
    deinit { process?.cancel(); transfer?.cancel() }
}
