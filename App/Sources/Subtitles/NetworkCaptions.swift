import Foundation

struct NetworkCaptionTrack: Equatable {
    let id: String
    let title: String
    let format: String
    let site: NetworkVideo.Site
    let url: URL?
    let inline: String?
    let headers: [String: String]
    static func allows(_ url: URL, site: NetworkVideo.Site) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        if site == .youtube { return ["youtube.com", "www.youtube.com"].contains(host) && url.path == "/api/timedtext" }
        return site == .bilibili && host.hasSuffix(".hdslb.com") && url.path.hasPrefix("/bfs/")
    }
    static func decode(_ data: Data, video: NetworkVideo) throws -> [Self] {
        let media = try ResolvedNetworkVideo.decode(data: data, request: video)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NetworkVideoFailure.invalidResponse }
        let rows = root["requested_subtitles"] as? [String: [String: Any]] ?? [:]
        guard rows.count <= 512 else { throw NetworkVideoFailure.invalidResponse }
        let manual = Set((root["subtitles"] as? [String: Any] ?? [:]).keys)
        return rows.compactMap { id, row -> Self? in
            guard id.count <= 80, id != "danmaku", id != "live_chat", let format = row["ext"] as? String,
                  ["srt", "vtt", "json3"].contains(format) else { return nil }
            let inline = row["data"] as? String
            let url = (row["url"] as? String).flatMap(URL.init(string:))
            guard (inline != nil && inline!.utf8.count <= SubtitleTranscript.maxBytes) || url.map({ allows($0, site: video.site) }) == true else { return nil }
            let language = Locale.current.localizedString(forLanguageCode: id.replacingOccurrences(of: "-orig", with: "")) ?? id
            return Self(id: id, title: L("网站字幕：%@", language), format: format, site: video.site, url: url, inline: inline, headers: media.headers)
        }.sorted { a, b in
            func sourceRank(_ track: Self) -> Int {
                if manual.contains(track.id) { return 0 }
                let translated = track.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.contains { $0.name == "tlang" && !($0.value ?? "").isEmpty } == true
                return translated ? 2 : 1
            }
            if sourceRank(a) != sourceRank(b) { return sourceRank(a) < sourceRank(b) }
            let preferred = Locale.preferredLanguages.map { String($0.split(separator: "-").first ?? "") } + ["zh", "en", "ja"]
            func rank(_ id: String) -> Int { preferred.firstIndex(where: { id == $0 || id.hasPrefix($0 + "-") }) ?? 999 }
            return rank(a.id) == rank(b.id) ? a.id < b.id : rank(a.id) < rank(b.id)
        }
    }
}

protocol NetworkCaptionCatalogLoading: AnyObject {
    func resolve(_ video: NetworkVideo, completion: @escaping (Result<[NetworkCaptionTrack], NetworkVideoFailure>) -> Void)
    func cancel()
}

/// Explicitly simulated metadata extraction: write-subs enables discovery, but
/// --simulate prevents files being created. Public sources, no credentials.
final class NetworkCaptionCatalog: NetworkCaptionCatalogLoading {
    private let tools: () -> NetworkVideoResolver.Tools?
    private let makeProcess: () -> NetworkVideoProcessRunning
    private var process: NetworkVideoProcessRunning?
    private var generation = 0
    init(tools: @escaping () -> NetworkVideoResolver.Tools? = NetworkVideoResolver.installedTools,
         makeProcess: @escaping () -> NetworkVideoProcessRunning = { NetworkVideoProcess() }) {
        self.tools = tools; self.makeProcess = makeProcess
    }
    static func arguments(for video: NetworkVideo, deno: String) -> [String] {
        let base = NetworkVideoResolver.arguments(for: video, deno: deno)
        return Array(base.dropLast(2)) + ["--simulate", "--write-subs", "--write-auto-subs", "--sub-langs", "all,-live_chat,-danmaku", "--sub-format", "json3/vtt/srt"] + Array(base.suffix(2))
    }
    func resolve(_ video: NetworkVideo, completion: @escaping (Result<[NetworkCaptionTrack], NetworkVideoFailure>) -> Void) {
        cancel()
        guard video.site != .biliShort else { completion(.failure(.invalidLink)); return }
        guard let tools = tools() else { completion(.failure(.missingTools)); return }
        guard video.site != .youtube || !tools.deno.isEmpty else { completion(.failure(.missingDeno)); return }
        let token = generation, process = makeProcess(); self.process = process
        process.run(executable: tools.executable, arguments: Self.arguments(for: video, deno: tools.deno)) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.process = nil
            completion(result.flatMap { data in Result { try NetworkCaptionTrack.decode(data, video: video) }.mapError { $0 as? NetworkVideoFailure ?? .invalidResponse } })
        }
    }
    func cancel() { generation += 1; process?.cancel(); process = nil }
    deinit { process?.cancel() }
}

/// Bounded, anonymous caption transfer. Redirects obey the same site policy.
final class CaptionTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let track: NetworkCaptionTrack
    private var completion: ((Result<Data, SubtitleLoadFailure>) -> Void)?
    private var session: URLSession?
    private var data = Data()
    private var redirects = 0
    init(track: NetworkCaptionTrack, completion: @escaping (Result<Data, SubtitleLoadFailure>) -> Void) { self.track = track; self.completion = completion }
    func start() {
        guard let url = track.url, NetworkCaptionTrack.allows(url, site: track.site) else { finish(.failure(.restricted)); return }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main); self.session = session
        var request = URLRequest(url: url)
        for (key, value) in track.headers where ["user-agent", "referer", "accept", "accept-language", "origin"].contains(key.lowercased()) {
            guard !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), value.utf8.count <= 4096 else { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        session.dataTask(with: request).resume()
    }
    func cancel() { completion = nil; session?.invalidateAndCancel(); session = nil }
    private func finish(_ result: Result<Data, SubtitleLoadFailure>) {
        let callback = completion; completion = nil; session?.invalidateAndCancel(); session = nil; callback?(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let url = request.url, NetworkCaptionTrack.allows(url, site: track.site) else { completionHandler(nil); finish(.failure(.restricted)); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { completionHandler(.cancel); finish(.failure(.restricted)); return }
        guard response.expectedContentLength <= Int64(SubtitleTranscript.maxBytes) else { completionHandler(.cancel); finish(.failure(.tooLarge)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count + bytes.count <= SubtitleTranscript.maxBytes else { finish(.failure(.tooLarge)); return }
        data.append(bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard completion != nil else { return }
        if let error { finish(.failure((error as NSError).code == NSURLErrorTimedOut ? .timeout : .restricted)) }
        else { finish(.success(data)) }
    }
}
