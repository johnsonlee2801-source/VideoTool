import AppKit

/// Who makes VideoTool: shown in the About window, on the first screen and in the
/// copyright line (2026-10-20).
enum About {
    static let author = "ChengNuo"
    static let links: [(title: String, url: URL)] = [
        ("GitHub", URL(string: "https://github.com/johnsonlee2801-source")!),
        ("blog.flowhunt.net", URL(string: "https://blog.flowhunt.net/")!),
    ]

    /// "Made by ChengNuo", the links, then the third-party notices.
    static func credits(notices: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        out.append(NSAttributedString(string: L("由 %@ 制作", author), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        out.append(NSAttributedString(string: "\n", attributes: body))
        for (i, link) in links.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ·  ", attributes: body)) }
            var attrs = body
            attrs[.link] = link.url
            out.append(NSAttributedString(string: link.title, attributes: attrs))
        }
        out.append(NSAttributedString(string: "\n\n", attributes: body))
        out.append(NSAttributedString(string: notices, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        return out
    }
}
