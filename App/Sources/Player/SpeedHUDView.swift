import AppKit

/// Top-centre overlay. While holding: a big speed read-out (pink when faster,
/// cyan when slower) and a mini scale; after release or for short messages: a flash.
final class SpeedHUDView: NSView, SpeedHUD {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// What the HUD says right now (tests).
    var text: String { label.stringValue }
    private let bar = NSView()
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint?
    private var flashWork: DispatchWorkItem?
    private let minSpeed: Double
    private let maxSpeed: Double

    init(minSpeed: Double = 0.5, maxSpeed: Double = 6.0) {
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.withAlphaComponent(0.9).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        isHidden = true

        icon.symbolConfiguration = .init(pointSize: 22, weight: .black)
        label.font = Theme.digits(38, .heavy)
        label.textColor = Theme.textPrimary
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        bar.layer?.cornerRadius = 2
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 2

        let row = NSStackView(views: [icon, label])
        row.spacing = 8
        for v in [row, bar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        fill.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(fill)
        let w = fill.widthAnchor.constraint(equalToConstant: 0)
        fillWidth = w
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 22),
            bar.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            bar.heightAnchor.constraint(equalToConstant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            fill.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            fill.topAnchor.constraint(equalTo: bar.topAnchor),
            fill.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            w,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }    // never steal clicks

    func show(speed: Double, dx: Double) {
        flashWork?.cancel()
        let faster = speed >= 1.0
        let tint = faster ? Theme.accent : Theme.accent2
        icon.image = NSImage(systemSymbolName: faster ? "forward.fill" : "backward.fill", accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.isHidden = false
        label.stringValue = PlaybackSpeed.label(speed)
        label.font = Theme.digits(38, .heavy)
        fill.layer?.backgroundColor = tint.cgColor
        let fraction = max(0, min(1, (speed - minSpeed) / (maxSpeed - minSpeed)))
        layoutSubtreeIfNeeded()
        fillWidth?.constant = max(4, bar.bounds.width * fraction)
        bar.isHidden = false
        isHidden = false
    }

    func hide() {
        flashWork?.cancel()
        isHidden = true
    }

    func flash(speed: Double) {
        flash(text: PlaybackSpeed.label(speed), symbol: "play.fill")      // 1.25×, not 1.3×
    }

    /// Brief message, e.g. "★ 12:34" after starring.
    func flash(text: String) { flash(text: text, symbol: nil) }

    private func flash(text: String, symbol: String?) {
        flashWork?.cancel()
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.contentTintColor = Theme.textPrimary
        icon.isHidden = symbol == nil
        label.stringValue = text
        label.font = Theme.display(22, .heavy)
        bar.isHidden = true
        isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.isHidden = true }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
