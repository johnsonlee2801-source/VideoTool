import AppKit
import Testing
@testable import VideoTool

// Keeps the redesign readable: WCAG 2.x contrast for every text/background pair in use.

@Suite struct ThemeTests {
    @Test("T1 contrast math matches WCAG reference values") func reference() {
        #expect(abs(Theme.contrast(.white, .black) - 21) < 0.01)
        #expect(abs(Theme.contrast(Theme.hex(0x777777), .white) - 4.48) < 0.02)
    }

    @Test("T2 body text: primary and secondary reach AA (4.5:1) on every surface") func bodyText() {
        for bg in [Theme.bg0, Theme.bg1, Theme.bg2] {
            #expect(Theme.contrast(Theme.textPrimary, bg) >= 7, "primary on \(bg)")
            #expect(Theme.contrast(Theme.textSecondary, bg) >= 4.5, "secondary on \(bg)")
        }
    }

    @Test("T3 placeholders and hints reach the large-text/UI minimum (3:1)") func tertiary() {
        for bg in [Theme.bg0, Theme.bg1, Theme.bg2] {
            #expect(Theme.contrast(Theme.textTertiary, bg) >= 3, "tertiary on \(bg)")
        }
    }

    @Test("T4 accents, stars and the cyan badge stand out from the dark surfaces (≥ 3:1)") func accents() {
        for color in [Theme.accent, Theme.accent2, Theme.star, Theme.violet] {
            for bg in [Theme.bg0, Theme.bg1, Theme.bg2] {
                #expect(Theme.contrast(color, bg) >= 3, "\(color) on \(bg)")
            }
        }
    }

    @Test("T5 white text on the accent button is readable (≥ 3:1, bold)") func buttonText() {
        #expect(Theme.contrast(.white, Theme.accent) >= 3)
    }
}
