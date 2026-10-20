import AppKit
import Testing
@testable import VideoTool

// Who made VideoTool, shown in the app (2026-10-20: "让所有人知道，这是由我们来制作的").

@Suite @MainActor struct AuthorTests {
    @Test("AU1 the About window says who made VideoTool, with links, above the third-party notices")
    func about() throws {
        let credits = About.credits(notices: "THIRD PARTY")
        let text = credits.string
        #expect(text.hasPrefix(L("由 %@ 制作", About.author)))
        #expect(text.contains("THIRD PARTY"))
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links == About.links.map(\.url))
        #expect(About.links.map(\.url.absoluteString) == ["https://github.com/johnsonlee2801-source", "https://blog.flowhunt.net/"])
    }

    @Test("AU2 the copyright line names the author")
    func copyright() {
        let line = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        #expect(line?.contains("ChengNuo") == true, "\(line ?? "nil")")
    }

    @Test("AU3 the first screen carries a small byline")
    func byline() {
        let view = EmptyStateView()
        func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
        #expect(texts(view).contains(L("由 %@ 制作", About.author)))
    }
}
