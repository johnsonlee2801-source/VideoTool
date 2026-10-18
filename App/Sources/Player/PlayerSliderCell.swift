import AppKit

/// Progress bar: thin dark track, pink→violet played part, white knob with an accent glow.
final class PlayerSliderCell: NSSliderCell {
    static let trackHeight: CGFloat = 4
    static let knobSize: CGFloat = 13

    override var knobThickness: CGFloat { Self.knobSize }

    override func barRect(flipped: Bool) -> NSRect {
        let r = super.barRect(flipped: flipped)
        return NSRect(x: r.minX, y: r.midY - Self.trackHeight / 2, width: r.width, height: Self.trackHeight)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - Self.trackHeight / 2, width: rect.width, height: Self.trackHeight)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let span = maxValue - minValue
        guard span > 0, isEnabled else { return }
        let fraction = CGFloat(min(max((doubleValue - minValue) / span, 0), 1))
        let played = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        if played.width > 0 {
            Theme.progressGradient.draw(in: NSBezierPath(roundedRect: played, xRadius: 2, yRadius: 2), angle: 0)
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        guard isEnabled else { return }
        let r = NSRect(x: knobRect.midX - Self.knobSize / 2, y: knobRect.midY - Self.knobSize / 2,
                       width: Self.knobSize, height: Self.knobSize)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = Theme.accent.withAlphaComponent(0.9)
        glow.shadowBlurRadius = 6
        glow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
