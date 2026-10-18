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

    static let clusterGap: CGFloat = 12

    /// Stars that would overlap are drawn as one star with a count ("★2").
    private func visibleClusters() -> [(bookmarks: [Bookmark], x: CGFloat)] {
        let placed = bookmarks.compactMap { b in x(for: b).map { (b, $0) } }
        return BookmarkNavigator.clusters(placed.map { Double($0.1) }, minGap: Double(Self.clusterGap)).map { group in
            (group.map { placed[$0].0 }, placed[group[0]].1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        for cluster in visibleClusters() {
            let isHovered = cluster.bookmarks.contains { $0.id == hovered }
            let star = NSMutableAttributedString(string: "★", attributes: [
                .font: NSFont.systemFont(ofSize: isHovered ? 16 : 12, weight: .black),
                .foregroundColor: Theme.star, .shadow: shadow])
            if cluster.bookmarks.count > 1 {
                star.append(NSAttributedString(string: "\(cluster.bookmarks.count)", attributes: [
                    .font: Theme.digits(9, .black), .foregroundColor: Theme.star, .shadow: shadow,
                    .baselineOffset: 4]))
            }
            let size = star.size()
            let starWidth = NSAttributedString(string: "★", attributes: [.font: NSFont.systemFont(ofSize: isHovered ? 16 : 12, weight: .black)]).size().width
            star.draw(at: NSPoint(x: cluster.x - starWidth / 2, y: bounds.midY - size.height / 2 - 10))
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
        let hit = visibleClusters()
            .map { ($0.bookmarks[0], $0.x) }
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

    static let fullSize = NSSize(width: 200, height: 146)
    static let compactSize = NSSize(width: 200, height: 34)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.fullSize))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = Theme.radiusCard
        layer?.borderWidth = 1
        layer?.borderColor = Theme.stroke.cgColor
        isHidden = true
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = Theme.radiusSmall
        image.layer?.masksToBounds = true
        label.textColor = Theme.textPrimary
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(image)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ b: Bookmark, thumbnail: URL?) {
        let time = TimeFormatting.string(b.time)
        let text = NSMutableAttributedString(string: "★ \(time)", attributes: [
            .foregroundColor: Theme.star, .font: Theme.digits(12, .heavy)])
        if !b.note.isEmpty {
            text.append(NSAttributedString(string: "  \(b.note)", attributes: [
                .foregroundColor: Theme.textPrimary, .font: NSFont.systemFont(ofSize: 12, weight: .bold)]))
        }
        label.attributedStringValue = text
        image.image = thumbnail.flatMap { NSImage(contentsOf: $0) }
        let hasImage = image.image != nil
        image.isHidden = !hasImage
        // Without a thumbnail the card shrinks to one line instead of an empty box.
        setFrameSize(hasImage ? Self.fullSize : Self.compactSize)
        image.frame = NSRect(x: 6, y: 32, width: bounds.width - 12, height: bounds.height - 38)
        label.frame = NSRect(x: 10, y: 7, width: bounds.width - 20, height: 20)
        isHidden = false
    }

    func hide() { isHidden = true }
}
