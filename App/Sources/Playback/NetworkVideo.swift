import Foundation

enum NetworkVideoFailure: Error, Equatable, LocalizedError {
    case invalidLink, missingTools, missingDeno, unsupported, invalidResponse, failed, timeout, cancelled, restricted, network, componentUpdate
    /// Only fixed categories leave the subprocess; never expose its raw text.
    static func classify(_ text: String) -> Self {
        let s = text.lowercased()
        if ["sign in", "login", "premium", "private video", "video unavailable", "http error 403", "http error 401", "http error 404", "permission denied"].contains(where: s.contains) { return .restricted }
        if ["timed out", "timeout", "unable to connect", "connection refused", "name resolution", "network is unreachable"].contains(where: s.contains) { return .network }
        if ["challenge", "javascript runtime", "unsupported url", "requested format is not available", "extractorerror"].contains(where: s.contains) { return .componentUpdate }
        return .failed
    }
    var errorDescription: String? {
        switch self {
        case .invalidLink: return L("请输入有效的 YouTube 或哔哩哔哩视频链接。")
        case .missingTools: return L("需要本机安装的 yt-dlp；YouTube 还需要 Deno。")
        case .missingDeno: return L("YouTube 解析需要本机 Deno，请检查组件安装。")
        case .restricted: return L("视频访问受限或已失效，可在浏览器中检查是否需要登录。")
        case .network: return L("无法连接视频网站，请检查网络后重试。")
        case .componentUpdate: return L("解析组件可能需要更新，请检查 yt-dlp 和 Deno 版本。")
        case .unsupported: return L("暂不支持直播、未发布或需要登录的视频。")
        case .invalidResponse: return L("未获得可用的视频流，请检查解析组件是否需要更新。")
        case .failed: return L("无法解析视频，请检查网络、视频可访问性及解析组件版本。")
        case .timeout: return L("解析超时，请检查网络后重试。")
        case .cancelled: return L("已取消解析。")
        }
    }
}

/// Stable public identity. Tracking/playlist parameters never reach the resolver.
struct NetworkVideo: Equatable {
    enum Site: Equatable { case youtube, bilibili, biliShort }
    let id: String
    let start: Double?
    var site: Site = .youtube
    var page: Int = 1
    var key: String { site == .youtube ? "youtube:" + id : "bilibili:" + id + ":p" + String(page) }
    var url: URL {
        switch site {
        case .youtube: return URL(string: "https://www.youtube.com/watch?v=" + id)!
        case .bilibili: return URL(string: "https://www.bilibili.com/video/" + id + "?p=" + String(page))!
        case .biliShort: return URL(string: "https://b23.tv/" + id)!
        }
    }
    func selecting(page: Int) throws -> Self {
        guard site == .bilibili, (1...1000).contains(page) else { throw NetworkVideoFailure.invalidLink }
        return try Self("https://www.bilibili.com/video/" + id + "?p=" + String(page))
    }

    init(_ text: String) throws {
        guard text.count <= 4096,
              let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(c.scheme?.lowercased() ?? ""),
              c.user == nil, c.password == nil, c.port == nil,
              let host = c.host?.lowercased() else { throw NetworkVideoFailure.invalidLink }
        let path = c.path.split(separator: "/").map(String.init)
        if ["bilibili.com", "www.bilibili.com", "m.bilibili.com", "b23.tv"].contains(host) {
            let query = c.queryItems ?? []
            if host == "b23.tv" {
                guard path.count == 1, path[0].range(of: "^[A-Za-z0-9]{1,32}$", options: .regularExpression) != nil else { throw NetworkVideoFailure.invalidLink }
                id = path[0]; start = nil; site = .biliShort; return
            }
            guard path.count == 2, path[0] == "video",
                  path[1].range(of: "^(BV[A-Za-z0-9]{10}|av[0-9]{1,15})$", options: .regularExpression) != nil,
                  query.filter({ $0.name == "p" }).count <= 1 else { throw NetworkVideoFailure.invalidLink }
            let rawPage = query.first { $0.name == "p" }?.value ?? "1"
            guard rawPage.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil, let p = Int(rawPage), (1...1000).contains(p) else { throw NetworkVideoFailure.invalidLink }
            id = path[1]; page = p; site = .bilibili
            start = query.first { $0.name == "t" }?.value.flatMap(Self.seconds)
            return
        }
        guard ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"].contains(host)
        else { throw NetworkVideoFailure.invalidLink }
        let query = c.queryItems ?? []
        let parts = c.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            candidate = parts.count == 1 ? parts[0] : nil
        } else if c.path == "/watch", query.filter({ $0.name == "v" }).count == 1 {
            candidate = query.first { $0.name == "v" }?.value
        } else if parts.count == 2, ["shorts", "embed", "live"].contains(parts[0]) {
            candidate = parts[1]
        } else { candidate = nil }
        guard let candidate, candidate.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
        else { throw NetworkVideoFailure.invalidLink }
        id = candidate
        let raw = query.first { $0.name == "t" }?.value ?? query.first { $0.name == "start" }?.value
            ?? c.fragment.flatMap { $0.hasPrefix("t=") ? String($0.dropFirst(2)) : nil }
        start = raw.flatMap(Self.seconds)
    }

    private static func seconds(_ text: String) -> Double? {
        guard text.count <= 20 else { return nil }
        if let seconds = Double(text), seconds.isFinite, seconds >= 0, seconds <= 604800 { return seconds }
        guard !text.isEmpty, text.range(of: "^(?:[0-9]+h)?(?:[0-9]+m)?(?:[0-9]+s)?$", options: .regularExpression) != nil
        else { return nil }
        var digits = "", total = 0.0
        for character in text {
            if character.isNumber { digits.append(character) } else {
                guard let number = Double(digits) else { return nil }
                total += number * (character == "h" ? 3600 : character == "m" ? 60 : 1)
                digits = ""
            }
        }
        return total.isFinite && total <= 604800 ? total : nil
    }
}

/// Ephemeral URLs stay in memory, never in the library, preferences or diagnostics.
struct ResolvedNetworkVideo {
    let request: NetworkVideo
    let title: String
    let videoURL: URL
    let audioURL: URL?
    let headers: [String: String]
    var parts: [BilibiliPart] = []
    var target: String { videoURL.isFileURL ? videoURL.path : videoURL.absoluteString }

    static func decode(data: Data, request: NetworkVideo) throws -> Self {
        guard data.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request.site != .biliShort,
              let responseID = object["id"] as? String,
              responseID == (request.site == .youtube ? request.id : request.id + "_p" + String(request.page)) || (request.site == .bilibili && request.page == 1 && responseID == request.id) else { throw NetworkVideoFailure.invalidResponse }
        if object["is_live"] as? Bool == true || ["is_live", "is_upcoming", "post_live"].contains(object["live_status"] as? String ?? "") {
            throw NetworkVideoFailure.unsupported
        }
        guard let duration = object["duration"] as? Double, duration.isFinite, duration > 0 else { throw NetworkVideoFailure.unsupported }
        let formats = object["requested_formats"] as? [[String: Any]] ?? [object]
        guard formats.count == 1 || formats.count == 2,
              // Only an explicit "none" means no track; Bilibili's legacy muxed formats omit codecs.
              let video = formats.first(where: { ($0["vcodec"] as? String) != "none" })
        else { throw NetworkVideoFailure.invalidResponse }
        let audio = formats.count == 2 ? formats.first(where: { ($0["vcodec"] as? String) == "none" && ($0["acodec"] as? String ?? "none") != "none" }) : nil
        guard formats.count == 1 ? (video["acodec"] as? String) != "none" : audio != nil
        else { throw NetworkVideoFailure.invalidResponse }
        func url(_ object: [String: Any]) throws -> URL {
            guard let raw = object["url"] as? String, let url = URL(string: raw),
                  url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, let host = url.host?.lowercased(),
                  (request.site == .youtube
                    ? (host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"))
                    : ["bilivideo.com", "bilivideo.cn", "bilivideo.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) })),
                  !raw.contains("\n"), !raw.contains("\r") else { throw NetworkVideoFailure.invalidResponse }
            return url
        }
        var headers = [String: String]()
        for source in [object] + formats {
            for (key, value) in source["http_headers"] as? [String: String] ?? [:] {
                guard key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), value.utf8.count <= 4096
                else { throw NetworkVideoFailure.invalidResponse }
                guard ["user-agent", "referer", "accept", "accept-language", "origin"].contains(key.lowercased()) else { continue }
                if let old = headers.first(where: { $0.key.lowercased() == key.lowercased() }), old.value != value {
                    throw NetworkVideoFailure.invalidResponse
                }
                headers[key] = value
            }
        }
        let title = (object["title"] as? String ?? request.id).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return Self(request: request, title: String(String(String.UnicodeScalarView(title)).prefix(300)),
                    videoURL: try url(video), audioURL: try audio.map(url), headers: headers)
    }

    /// mpv's length quoting counts bytes, not Unicode characters. File options
    /// are restored by mpv before the next file; embedded commas cannot add options.
    static func quote(_ value: String) -> String { "%\(value.utf8.count)%" + value }
    var loadCommand: [String] {
        var options = ["force-media-title=" + Self.quote(title), "network-timeout=20", "tls-verify=yes"]
        if let audioURL { options.append("audio-files-append=" + Self.quote(audioURL.absoluteString)) }
        if !headers.isEmpty {
            // String-list options use backslash escaping, unlike the surrounding
            // loadfile key/value map. Length quotes here would be sent as headers.
            let list = headers.sorted { $0.key < $1.key }.map {
                ($0.key + ": " + $0.value).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
            }.joined(separator: ",")
            options.append("http-header-fields=" + Self.quote(list))
        }
        return ["loadfile", target, "replace", "-1", options.joined(separator: ",")]
    }
}
