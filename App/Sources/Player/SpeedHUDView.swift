import AppKit

/// Top-centre overlay: big speed read-out plus a thin position bar while
/// holding, and a short flash after release.
final class SpeedHUDView: NSView, SpeedHUD {
    private let label = NSTextField(labelWithString: "")
    private let bar = NSView()
    private let marker = NSView()
    private var flashWork: DispatchWorkItem?
    private let minSpeed: Double
    private let maxSpeed: Double

    init(minSpeed: Double = 0.5, maxSpeed: Double = 6.0) {
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 12
        isHidden = true

        label.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        bar.layer?.cornerRadius = 2
        bar.translatesAutoresizingMaskIntoConstraints = false

        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.white.cgColor
        marker.layer?.cornerRadius = 5
        marker.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(bar)
        bar.addSubview(marker)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 260),
            heightAnchor.constraint(equalToConstant: 78),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            bar.heightAnchor.constraint(equalToConstant: 4),
            marker.widthAnchor.constraint(equalToConstant: 10),
            marker.heightAnchor.constraint(equalToConstant: 10),
            marker.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        markerX = marker.leadingAnchor.constraint(equalTo: bar.leadingAnchor)
        markerX?.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var markerX: NSLayoutConstraint?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }    // never steal clicks

    func show(speed: Double, dx: Double) {
        flashWork?.cancel()
        let arrow = speed > 1.0 ? "▶▶" : (speed < 1.0 ? "◀◀" : "▶")
        label.stringValue = String(format: "%@ %.1f×", arrow, speed)
        let fraction = max(0, min(1, (speed - minSpeed) / (maxSpeed - minSpeed)))
        markerX?.constant = (bar.bounds.width > 0 ? bar.bounds.width - 10 : 210) * fraction
        bar.isHidden = false
        isHidden = false
    }

    func hide() {
        flashWork?.cancel()
        isHidden = true
    }

    func flash(speed: Double) {
        flashWork?.cancel()
        label.stringValue = String(format: "▶ %.1f×", speed)
        bar.isHidden = true
        isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.isHidden = true }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
