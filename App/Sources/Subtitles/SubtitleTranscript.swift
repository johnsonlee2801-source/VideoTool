import Foundation

enum SubtitleLoadFailure: Error, LocalizedError, Equatable {
    case missingFFmpeg, unavailable, tooLarge, invalidText, timeout, cancelled, restricted
    var errorDescription: String? {
        switch self {
        case .missingFFmpeg: return L("读取内嵌字幕需要本机 FFmpeg／ffprobe，也可以先选择已有 SRT 或本机 AI 字幕。")
        case .unavailable: return L("没有可读取的文字字幕；图片字幕暂不支持搜索。")
        case .tooLarge: return L("字幕超过读取上限，请选择较小的文字字幕。")
        case .invalidText: return L("字幕格式或编码无法识别，请使用 UTF-8／UTF-16 文字字幕。")
        case .timeout: return L("字幕读取超时，可重试或切换字幕来源。")
        case .cancelled: return L("已取消字幕读取。")
        case .restricted: return L("网站字幕暂时无法读取，可能有访问限制；请在浏览器中检查。")
        }
    }
}

struct SubtitleTranscript: Equatable {
    static let maxBytes = 4 * 1024 * 1024
    let cues: [SubtitleCue]
    private let textKeys: [String]
    private let compactKeys: [String]
    private static func folded(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    init(cues: [SubtitleCue]) {
        func clean(_ value: String) -> String {
            String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let valid = cues.prefix(30000).compactMap { cue -> SubtitleCue? in
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start, cue.start < SRT.maxSeconds else { return nil }
            let text = clean(cue.text)
            guard !text.isEmpty else { return nil }
            return SubtitleCue(start: cue.start, end: min(SRT.maxSeconds, cue.end), text: text, translation: cue.translation.map(clean))
        }.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return (a.text + (a.translation ?? "")) < (b.text + (b.translation ?? ""))
        }
        var unique: [SubtitleCue] = []
        for cue in valid where unique.last != cue { unique.append(cue) }
        self.cues = unique
        textKeys = unique.map { Self.folded($0.text + " " + ($0.translation ?? "")) }
        compactKeys = textKeys.map { $0.replacingOccurrences(of: " ", with: "") }
    }
    func matches(_ query: String) -> [Int] {
        let query = Self.folded(query)
        guard !query.isEmpty else { return Array(cues.indices.prefix(1000)) }
        let compact = query.replacingOccurrences(of: " ", with: "")
        var matches: [Int] = []
        for index in cues.indices where textKeys[index].contains(query) || compactKeys[index].contains(compact) {
            matches.append(index)
            if matches.count == 1000 { break }
        }
        return matches
    }
    /// Replay the phrase just heard. Close to a cue's start, step back one more.
    func replayIndex(at time: Double) -> Int? {
        guard time.isFinite else { return nil }
        let target = time - 0.4
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= target { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
    static func decode(_ data: Data, format: String, bilingual: Bool = false) throws -> Self {
        guard data.count <= maxBytes else { throw SubtitleLoadFailure.tooLarge }
        if format == "json3" {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let events = root["events"] as? [[String: Any]] else { throw SubtitleLoadFailure.invalidText }
            let cues = events.prefix(30000).compactMap { event -> SubtitleCue? in
                guard let start = event["tStartMs"] as? Double, let segments = event["segs"] as? [[String: Any]] else { return nil }
                let duration = event["dDurationMs"] as? Double ?? 2000
                guard duration.isFinite, duration > 0 else { return nil }
                let text = segments.compactMap { $0["utf8"] as? String }.joined()
                return SubtitleCue(start: start / 1000, end: (start + duration) / 1000, text: text)
            }
            return Self(cues: cues)
        }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw SubtitleLoadFailure.invalidText }
        if format == "srt" { return Self(cues: SRT.parse(text, bilingual: bilingual)) }
        guard format == "vtt" else { throw SubtitleLoadFailure.invalidText }
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        let cues = blocks.compactMap { block -> SubtitleCue? in
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[index].components(separatedBy: "-->")
            guard parts.count == 2, let start = TimeFormatting.parse(parts[0]),
                  let stamp = parts[1].split(whereSeparator: \.isWhitespace).first, let end = TimeFormatting.parse(String(stamp)) else { return nil }
            var body = lines.dropFirst(index + 1).joined(separator: "\n").replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&#39;", "'"), ("&amp;", "&")] { body = body.replacingOccurrences(of: entity, with: value) }
            return SubtitleCue(start: start, end: end, text: body)
        }
        return Self(cues: cues)
    }
}
