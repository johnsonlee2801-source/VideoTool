import Foundation

struct BilibiliPart: Equatable {
    let page: Int
    let title: String
}
struct BilibiliCatalog {
    let request: NetworkVideo
    let parts: [BilibiliPart]
    static func decode(_ data: Data, request: NetworkVideo) throws -> Self {
        guard data.count <= 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NetworkVideoFailure.invalidResponse }
        if let code = root["code"] as? Int, [-101, -403, -10403, -404].contains(code) { throw NetworkVideoFailure.restricted }
        guard root["code"] as? Int == 0, let video = root["data"] as? [String: Any],
              let bvid = video["bvid"] as? String, bvid.hasPrefix("BV"),
              let pages = video["pages"] as? [[String: Any]], !pages.isEmpty, pages.count <= 1000,
              request.site == .bilibili else { throw NetworkVideoFailure.invalidResponse }
        if request.id.hasPrefix("BV"), bvid != request.id { throw NetworkVideoFailure.invalidResponse }
        if request.id.hasPrefix("av"), String(video["aid"] as? Int ?? -1) != String(request.id.dropFirst(2)) { throw NetworkVideoFailure.invalidResponse }
        if video["is_upower_exclusive"] as? Bool == true || (video["rights"] as? [String: Any])?["pay"] as? Int == 1 {
            throw NetworkVideoFailure.unsupported
        }
        let parts = try pages.enumerated().map { i, row -> BilibiliPart in
            guard row["page"] as? Int == i + 1, let title = row["part"] as? String else { throw NetworkVideoFailure.invalidResponse }
            return BilibiliPart(page: i + 1, title: String(String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(160)))
        }
        guard request.page <= parts.count else { throw NetworkVideoFailure.invalidLink }
        let canonical = try NetworkVideo("https://www.bilibili.com/video/" + bvid + "?p=" + String(request.page) + (request.start.map { "&t=" + String($0) } ?? ""))
        return Self(request: canonical, parts: parts)
    }
}

protocol BilibiliCatalogFetching: AnyObject {
    func fetch(_ video: NetworkVideo, completion: @escaping (Result<BilibiliCatalog, NetworkVideoFailure>) -> Void)
    func cancel()
}

/// Anonymous, bounded metadata only. No shared cookies, credentials or disk cache.
final class BilibiliCatalogFetcher: BilibiliCatalogFetching {
    private var transfer: BilibiliTransfer?
    private var generation = 0
    func fetch(_ video: NetworkVideo, completion: @escaping (Result<BilibiliCatalog, NetworkVideoFailure>) -> Void) {
        cancel()
        let token = generation
        func catalog(_ request: NetworkVideo) {
            let query = request.id.hasPrefix("BV") ? "bvid=" + request.id : "aid=" + String(request.id.dropFirst(2))
            let url = URL(string: "https://api.bilibili.com/x/web-interface/view?" + query)!
            self.transfer = BilibiliTransfer(url: url, shortLink: false) { [weak self] result in
                guard let self, self.generation == token else { return }
                self.transfer = nil
                completion(result.flatMap { pair in Result { try BilibiliCatalog.decode(pair.0, request: request) }.mapError { $0 as? NetworkVideoFailure ?? .invalidResponse } })
            }
            self.transfer?.start()
        }
        if video.site == .biliShort {
            transfer = BilibiliTransfer(url: video.url, shortLink: true) { [weak self] result in
                guard let self, self.generation == token else { return }
                self.transfer = nil
                switch result {
                case .success(let pair):
                    guard let request = try? NetworkVideo(pair.1.absoluteString), request.site == .bilibili else { completion(.failure(.invalidLink)); return }
                    catalog(request)
                case .failure(let error): completion(.failure(error))
                }
            }
            transfer?.start()
        } else { catalog(video) }
    }
    func cancel() { generation += 1; transfer?.cancel(); transfer = nil }
    deinit { transfer?.cancel() }
}

private final class BilibiliTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let shortLink: Bool
    private var completion: ((Result<(Data, URL), NetworkVideoFailure>) -> Void)?
    private var session: URLSession?
    private var data = Data()
    private var redirects = 0
    init(url: URL, shortLink: Bool, completion: @escaping (Result<(Data, URL), NetworkVideoFailure>) -> Void) {
        self.url = url; self.shortLink = shortLink; self.completion = completion
    }
    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
    }
    func cancel() { completion = nil; session?.invalidateAndCancel(); session = nil }
    private func finish(_ result: Result<(Data, URL), NetworkVideoFailure>) {
        let callback = completion; completion = nil
        session?.invalidateAndCancel(); session = nil
        callback?(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard shortLink, redirects <= 5, let target = request.url, target.scheme == "https",
              target.user == nil, target.password == nil, target.port == nil else {
            completionHandler(nil); finish(.failure(.invalidLink)); return
        }
        if let video = try? NetworkVideo(target.absoluteString), video.site == .bilibili {
            completionHandler(nil); finish(.success((Data(), target))); return
        }
        guard target.host == "b23.tv" else { completionHandler(nil); finish(.failure(.invalidLink)); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !shortLink, let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 1024 * 1024 else {
            completionHandler(.cancel); finish(.failure(NetworkVideoFailure.classify("HTTP Error " + String((response as? HTTPURLResponse)?.statusCode ?? 0)))); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count + bytes.count <= 1024 * 1024 else { finish(.failure(.invalidResponse)); return }
        data.append(bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard completion != nil else { return }
        if let error { finish(.failure((error as NSError).code == NSURLErrorTimedOut ? .timeout : .network)) }
        else { finish(.success((data, url))) }
    }
}
