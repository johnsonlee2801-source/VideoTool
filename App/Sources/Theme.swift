import AppKit

/// VideoTool's visual system (2026-10-18 redesign: "sharper, younger").
/// Deep near-black surfaces, one hot accent with a cyan partner, a pink→violet
/// progress gradient, bright yellow stars, bold type, small crisp radii.
/// Text colours are pinned by WCAG contrast tests (ThemeTests).
enum Theme {
    // MARK: colours

    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    /// Window / video surround.
    static let bg0 = hex(0x0A0A0F)
    /// Panels, sidebar, control bar.
    static let bg1 = hex(0x13131A)
    /// Cards, chips, rows.
    static let bg2 = hex(0x1D1D27)
    /// Hairlines and borders.
    static let stroke = hex(0x2C2C3A)

    static let textPrimary = hex(0xF5F5F7)
    static let textSecondary = hex(0xA9A9BC)
    /// Placeholders and hints only (large-text contrast).
    static let textTertiary = hex(0x8E8EA3)          // ≥ 4.5:1 on bg2: small hint text too

    /// Hot pink: primary actions, selection, "faster".
    static let accent = hex(0xFF2E63)
    /// Cyan: secondary highlights, "slower", resolution badges.
    static let accent2 = hex(0x08D9D6)
    /// End of the progress gradient.
    static let violet = hex(0x7B61FF)
    /// Stars.
    static let star = hex(0xFFD60A)

    static var progressGradient: NSGradient { NSGradient(starting: accent, ending: violet)! }

    // MARK: shape

    static let radiusCard: CGFloat = 8
    static let radiusSmall: CGFloat = 5

    // MARK: type

    static func display(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    // MARK: contrast (WCAG 2.x)

    static func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB) ?? c
        func lin(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    // MARK: helpers

    /// A rounded "chip" label (tags, badges, hints).
    static func chip(_ text: String, color: NSColor = textSecondary, background: NSColor = bg2,
                     font: NSFont = .systemFont(ofSize: 11, weight: .semibold)) -> NSTextField {
        let label = PaddedLabel(text, inset: NSSize(width: 7, height: 2))
        label.font = font
        label.textColor = color
        label.wantsLayer = true
        label.layer?.backgroundColor = background.cgColor
        label.layer?.cornerRadius = radiusSmall
        return label
    }
}

/// A label with padding (NSTextField has no content insets).
final class PaddedLabel: NSTextField {
    private let inset: NSSize
    init(_ text: String, inset: NSSize) {
        self.inset = inset
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
        lineBreakMode = .byTruncatingTail
        alignment = .center
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + inset.width * 2, height: s.height + inset.height * 2)
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: inset.width, dy: inset.height)
        let attrs: [NSAttributedString.Key: Any] = [.font: font as Any, .foregroundColor: textColor as Any]
        let str = NSAttributedString(string: stringValue, attributes: attrs)
        let h = str.size().height
        str.draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h))
    }
}
