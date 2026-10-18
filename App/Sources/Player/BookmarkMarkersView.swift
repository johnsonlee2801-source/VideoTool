import AppKit

/// Draws yellow stars over the progress slider and reports hovering. It never
/// takes clicks (clicks go to the slider, which snaps to nearby stars).
final class BookmarkMarkersView: NSView {
    static let hoverRadius: CGFloat = 7

    weak var slider: NSSlider?
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var bookmarks: [Bookmark] = [] { didSet { needsDisplay = true } }
    /// Called with the hovered star (or nil) and its x in this view's coordinates.
    var onHover: ((Bookmark?, CGFloat) -> Void)?

    private var hovered: UUID?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Usable track of the slider, in this view's coordinates.
    func track() -> (minX: Double, width: Double) {
        guard let slider else { return (0, Double(bounds.width)) }
        let knob = (slider.cell as? NSSliderCell)?.knobThickness ?? 12
        let frame = convert(slider.bounds, from: slider)
        return (Double(frame.minX + knob / 2), Double(max(frame.width - knob, 1)))
    }

    func x(for b: Bookmark) -> CGFloat? {
        let t = track()
        return BookmarkNavigator.markerX(time: b.time, duration: duration, trackMinX: t.minX, trackWidth: t.width)
            .map { CGFloat($0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        for b in bookmarks {
            guard let x = x(for: b) else { continue }
            let isHovered = b.id == hovered
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isHovered ? NSFont.systemFont(ofSize: 14, weight: .bold) : font,
                .foregroundColor: NSColor.systemYellow,
                .shadow: { let s = NSShadow(); s.shadowColor = .black; s.shadowBlurRadius = 2; return s }(),
            ]
            let star = NSAttributedString(string: "★", attributes: attrs)
            let size = star.size()
            star.draw(at: NSPoint(x: x - size.width / 2, y: bounds.midY - size.height / 2 - 6))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = bookmarks
            .compactMap { b in x(for: b).map { (b, $0) } }
            .filter { abs($0.1 - p.x) <= Self.hoverRadius }
            .min { abs($0.1 - p.x) < abs($1.1 - p.x) }
        if hit?.0.id != hovered {
            hovered = hit?.0.id
            needsDisplay = true
            onHover?(hit?.0, hit?.1 ?? 0)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
        onHover?(nil, 0)
    }
}

/// Floating card above the progress bar: thumbnail, time and note of a star.
final class BookmarkPreviewView: NSView {
    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 132))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 8
        isHidden = true
        image.imageScaling = .scaleProportionallyUpOrDown
        image.frame = NSRect(x: 6, y: 30, width: 168, height: 96)
        label.frame = NSRect(x: 6, y: 6, width: 168, height: 20)
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(image)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ b: Bookmark, thumbnail: URL?) {
        let time = TimeFormatting.string(b.time)
        label.stringValue = b.note.isEmpty ? "★ \(time)" : "★ \(time)  \(b.note)"
        image.image = thumbnail.flatMap { NSImage(contentsOf: $0) }
        image.isHidden = image.image == nil
        isHidden = false
    }

    func hide() { isHidden = true }
}
