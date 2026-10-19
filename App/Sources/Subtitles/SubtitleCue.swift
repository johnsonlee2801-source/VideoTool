import Foundation

/// One subtitle on screen: the recognised text and, optionally, its translation.
struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
    var translation: String?
}

/// A word (or token) with its time in the audio, as recognition reports it.
struct SpeechWord: Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// One recognised stretch of speech (about a sentence), with word timings if known.
struct SpeechSegment: Equatable {
    var text: String
    var start: Double
    var end: Double
    var words: [SpeechWord]
}

/// Turns recognised sentences into readable cues: at most two lines' worth of text
/// and a few seconds each, split at clause ends where possible, never overlapping.
enum CueShaper {
    /// Two lines of ~42 Latin characters (a CJK character counts as two).
    static let maxWidth = 84
    static let maxDuration = 6.5
    static let minDuration = 0.5
    /// A clause break is used only if the cue before it is at least this wide.
    static let minClauseWidth = 20

    static func cues(from segments: [SpeechSegment]) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for seg in segments {
            let tokens = tokens(of: seg)
            guard !tokens.isEmpty else { continue }
            out += split(tokens)
        }
        return settle(out)
    }

    // MARK: width

    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    static func isWide(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3040...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD: return true
        default: return false
        }
    }

    // MARK: private

    /// Word timings when recognition gave them; otherwise words (or, for text
    /// without spaces, characters) with times shared out by character count.
    private static func tokens(of seg: SpeechSegment) -> [SpeechWord] {
        let given = seg.words.compactMap { w -> SpeechWord? in
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : SpeechWord(text: t, start: w.start, end: w.end)
        }
        if !given.isEmpty { return given }
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let pieces: [String] = text.contains(" ")
            ? text.split(whereSeparator: \.isWhitespace).map(String.init)
            : text.map(String.init)
        let total = Double(pieces.reduce(0) { $0 + $1.count })
        let span = max(seg.end - seg.start, 0)
        var at = 0.0
        return pieces.map { p in
            let s = seg.start + span * at / total
            at += Double(p.count)
            return SpeechWord(text: p, start: s, end: seg.start + span * at / total)
        }
    }

    /// Joins tokens with a space, except next to CJK characters.
    static func join(_ tokens: [SpeechWord]) -> String {
        var s = ""
        for t in tokens {
            if let last = s.unicodeScalars.last, let first = t.text.unicodeScalars.first,
               !isWide(last), !isWide(first) { s += " " }
            s += t.text
        }
        return s
    }

    private static func endsClause(_ token: String) -> Bool {
        guard let c = token.last else { return false }
        return ",.;:?!，。；：？！、…".contains(c)          // logic, not interface text
    }

    /// Greedy fill; when the next token would overflow, break at the last clause end
    /// in the chunk if it leaves a reasonable first part, else just before the token.
    private static func split(_ tokens: [SpeechWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var chunk: [SpeechWord] = []
        func emit(_ part: [SpeechWord]) {
            guard let f = part.first, let l = part.last else { return }
            cues.append(SubtitleCue(start: f.start, end: l.end, text: join(part)))
        }
        for t in tokens {
            let candidate = chunk + [t]
            let fits = displayWidth(join(candidate)) <= maxWidth
                && (candidate.last!.end - candidate.first!.start) <= maxDuration
            if fits || chunk.isEmpty { chunk = candidate; continue }
            if let i = chunk.indices.dropLast().last(where: { endsClause(chunk[$0].text) }),
               displayWidth(join(Array(chunk[...i]))) >= minClauseWidth {
                emit(Array(chunk[...i]))
                chunk = Array(chunk[(i + 1)...]) + [t]
            } else {
                emit(chunk)
                chunk = [t]
            }
        }
        emit(chunk)
        return cues
    }

    /// In time order, no overlaps, each at least `minDuration` long where there is room.
    private static func settle(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for var c in cues.sorted(by: { $0.start < $1.start }) {
            if let prev = out.last { c.start = max(c.start, prev.end) }
            c.end = max(c.end, c.start + minDuration)
            out.append(c)
        }
        return out
    }
}

/// SubRip (.srt), which mpv loads directly. Bilingual cues show the translation
/// first, then the original.
enum SRT {
    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Reads cues back. `bilingual`: the first line of each cue is the translation
    /// (as `document` writes it), the rest the original.
    static func parse(_ text: String, bilingual: Bool) -> [SubtitleCue] {
        parse(text).map { c in
            guard bilingual else { return c }
            var lines = c.text.components(separatedBy: "\n")
            guard lines.count >= 2 else { return c }
            let translation = lines.removeFirst()
            return SubtitleCue(start: c.start, end: c.end, text: lines.joined(separator: "\n"), translation: translation)
        }
    }

    /// Reads cues back (text lines joined with newlines; no translation split).
    static func parse(_ text: String) -> [SubtitleCue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let t = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let ends = lines[t].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count == 2, let start = seconds(ends[0]), let end = seconds(ends[1]) else { return nil }
            let body = lines[(t + 1)...].joined(separator: "\n")
            return body.isEmpty ? nil : SubtitleCue(start: start, end: end, text: body)
        }
    }

    /// "HH:MM:SS,mmm" (or with a dot) → seconds.
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func document(_ cues: [SubtitleCue]) -> String {
        var out = ""
        var number = 0
        for c in cues {
            let lines = [c.translation, c.text].compactMap { $0 }
                .flatMap { $0.components(separatedBy: .newlines) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            number += 1
            out += "\(number)\n\(timestamp(c.start)) --> \(timestamp(c.end))\n" + lines.joined(separator: "\n") + "\n\n"
        }
        return out.isEmpty ? "" : String(out.dropLast())
    }
}

/// Advanced SubStation (.ass), what the player shows for AI subtitles: the
/// translation above the original in one block, and optionally a semi-transparent
/// band over the bottom of the picture that hides subtitles burnt into the video
/// (user request 2026-10-19). Coordinates are in a 1920×1080 frame the player
/// scales to the picture, so the band always fits the video, not the window.
enum ASS {
    /// Band: bottom 23% of the picture, black at ~87% opacity (alpha 0x22; 0xFF = transparent).
    /// Tuned 2026-10-19 on white burnt-in text with a black outline: at 78% it still
    /// competed with the AI lines; at ~87% it fades to a trace while the picture shows through.
    static let bandTop = 830, bandHeight = 250
    static let bandAlpha = 0x22

    static func document(_ cues: [SubtitleCue], band: Bool, until videoEnd: Double) -> String {
        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        ScaledBorderAndShadow: yes
        WrapStyle: 0

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Text,PingFang SC,56,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,2.6,0.6,2,80,80,48,1
        Style: Band,Arial,20,&H00000000,&H00000000,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        if band, let last = [videoEnd, cues.map(\.end).max() ?? 0].max(), last > 0 {
            let alpha = String(format: "%02X", bandAlpha)
            out += "Dialogue: 0,\(time(0)),\(time(last)),Band,,0,0,0,,{\\an7\\pos(0,\(bandTop))\\bord0\\shad0\\1c&H000000&\\1a&H\(alpha)&\\p1}"
                + "m 0 0 l 1920 0 l 1920 \(bandHeight) l 0 \(bandHeight){\\p0}\n"
        }
        for c in cues {
            let original = escape(c.text)
            let text = c.translation.map { "{\\fs64}\(escape($0))\\N{\\fs52\\c&HE0E0E0&}\(original)" } ?? original
            out += "Dialogue: 1,\(time(c.start)),\(time(c.end)),Text,,0,0,0,,\(text)\n"
        }
        return out
    }

    /// H:MM:SS.cc
    static func time(_ seconds: Double) -> String {
        let cs = Int((max(seconds, 0) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    /// Braces would start style codes; newlines become ASS line breaks.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
            .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: "\\N")
    }
}
