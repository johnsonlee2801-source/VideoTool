import AppKit

/// Draws yellow stars just above the progress slider, reports hovering, and takes
/// clicks that land on a star. Every other click falls through to the slider
/// (which also snaps to nearby stars).
final class BookmarkMarkersView: NSView {
    static let hoverRadius: CGFloat = 7

    weak var slider: NSSlider?
    var duration: Double = 0 { didSet { needsDisplay = true } }
    /// The clip being marked with C: its first end, then the whole stretch (drawn in cyan).
    var clipStart: Double? { didSet { needsDisplay = true } }
    var clipRange: ClipRange? { didSet { needsDisplay = true } }
    var bookmarks: [Bookmark] = [] {
        didSet {
            needsDisplay = true
            // The hovered star is gone (undone, deleted, another file): close its preview now.
            if let h = hovered, !bookmarks.contains(where: { $0.id == h }) {
                hovered = nil
                onHover?(nil, 0)
            }
        }
    }
    /// Called with the hovered star (or nil) and its x in this view's coordinates.
    var onHover: ((Bookmark?, CGFloat) -> Void)?
    /// The time under the mouse when it is over the bar but not on a star (nil: none).
    var onHoverTime: ((Double?, CGFloat) -> Void)?
    /// A star was clicked (for a cluster, its earliest star).
    var onClick: ((Bookmark) -> Void)?

    private var hovered: UUID?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// Stars are drawn this far above the slider's centre line.
    static let starLift: CGFloat = 10
    var starCenterY: CGFloat { bounds.midY - Self.starLift }

    /// Only a star takes the click; `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let p = convert(point, from: superview)
        return abs(p.y - starCenterY) <= Self.starLift - 1 && star(atX: p.x) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let b = star(atX: p.x)?.bookmark { onClick?(b) }
    }

    /// The star (cluster) nearest to `x`, within the hover radius.
    private func star(atX x: CGFloat) -> (bookmark: Bookmark, x: CGFloat)? {
        visibleClusters()
            .map { ($0.bookmarks[0], $0.x) }
            .filter { abs($0.1 - x) <= Self.hoverRadius }
            .min { abs($0.1 - x) < abs($1.1 - x) }
    }

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

    private func x(at time: Double) -> CGFloat? {
        let t = track()
        return BookmarkNavigator.markerX(time: time, duration: duration, trackMinX: t.minX, trackWidth: t.width).map { CGFloat($0) }
    }

    /// The clip: a cyan band along the track, with a tick at each end.
    private func drawClip() {
        let y = bounds.midY
        if let r = clipRange, let a = x(at: r.start), let b = x(at: r.end) {
            Theme.accent2.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: a, y: y - 5, width: max(b - a, 2), height: 10), xRadius: 3, yRadius: 3).fill()
        }
        Theme.accent2.setFill()
        for t in [clipRange?.start ?? clipStart, clipRange?.end].compactMap({ $0 }) {
            if let px = x(at: t) { NSRect(x: px - 1, y: y - 8, width: 2, height: 16).fill() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawClip()
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
            star.draw(at: NSPoint(x: cluster.x - starWidth / 2, y: starCenterY - size.height / 2))
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
        let x = convert(event.locationInWindow, from: nil).x
        let hit = star(atX: x)
        if hit?.0.id != hovered {
            hovered = hit?.0.id
            needsDisplay = true
            onHover?(hit?.0, hit?.1 ?? 0)
        }
        onHoverTime?(hit == nil ? time(atX: x) : nil, x)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverTime?(nil, 0)
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
        onHover?(nil, 0)
    }

    /// The time at `x` on the bar (nil off the bar or with nothing loaded).
    func time(atX x: CGFloat) -> Double? {
        let t = track()
        guard duration > 0, t.width > 0, Double(x) >= t.minX - 2, Double(x) <= t.minX + t.width + 2 else { return nil }
        return min(max((Double(x) - t.minX) / t.width, 0), 1) * duration
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

    /// Hover on the bar away from stars: the time, and the frame once it is ready.
    func showTime(_ time: Double, image: NSImage?) {
        label.attributedStringValue = NSAttributedString(string: TimeFormatting.string(time), attributes: [
            .foregroundColor: Theme.textPrimary, .font: Theme.digits(13, .heavy)])
        self.image.image = image
        self.image.isHidden = image == nil
        setFrameSize(image == nil ? Self.compactSize : Self.fullSize)
        self.image.frame = NSRect(x: 6, y: 32, width: bounds.width - 12, height: bounds.height - 38)
        label.frame = NSRect(x: 10, y: 7, width: bounds.width - 20, height: 20)
        isHidden = false
    }

    /// For tests: what the card shows.
    var text: String { label.stringValue }
    var hasImage: Bool { image.image != nil && !image.isHidden }

    func hide() { isHidden = true }
}
