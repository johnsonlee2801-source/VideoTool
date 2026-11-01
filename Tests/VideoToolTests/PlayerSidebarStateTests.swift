import AppKit
import Testing
@testable import VideoTool

@Suite @MainActor struct PlayerSidebarStateTests {
    @Test("SS1 tabs expand, switch and close without losing the last selection")
    func transitions() {
        var s = PlayerSidebarState()
        #expect(!s.isExpanded && s.tab == .library && s.preferredWidth == 380)
        s.show(.recent)
        #expect(s.isExpanded && s.tab == .recent)
        s.toggleStars()
        #expect(s.isExpanded && s.tab == .stars)
        s.toggleStars()
        #expect(!s.isExpanded && s.tab == .stars)
        s.show(.library); s.close()
        #expect(!s.isExpanded && s.tab == .library)
    }

    @Test("SS2 sidebar width stays bounded and always leaves 240 points for the picture")
    func widths() {
        var s = PlayerSidebarState()
        s.show(.library)
        #expect(s.fittedWidth(available: 1280) == 380)
        #expect(s.fittedWidth(available: 520) == 280)
        s.preferredWidth = 900
        #expect(s.fittedWidth(available: 1280) == 560)
        s.preferredWidth = 10
        #expect(s.fittedWidth(available: 900) == 280)
        s.preferredWidth = .nan
        #expect(s.fittedWidth(available: 900) == 380)
        #expect(s.fittedWidth(available: 200) == 0)
        s.close()
        #expect(s.fittedWidth(available: 1280) == 0)
    }

    @Test("SS3 preferences restore width, visibility and the last tab using an isolated defaults store")
    func preferences() throws {
        let name = "videotool-sidebar-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let p = PlayerSidebarPreferences(defaults: d)
        #expect(p.load() == PlayerSidebarState())
        var s = PlayerSidebarState()
        s.show(.recent); s.preferredWidth = 445
        p.save(s)
        #expect(PlayerSidebarPreferences(defaults: d).load() == s)
        s.close(); p.save(s)
        #expect(!p.load().isExpanded && p.load().tab == .recent)
    }
}
