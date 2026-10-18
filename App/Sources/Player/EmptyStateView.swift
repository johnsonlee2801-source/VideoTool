import AppKit

/// What the player shows before a video is open: what to do, and the three
/// moves that make VideoTool different, as chips.
final class EmptyStateView: NSView {
    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 56, weight: .bold)
        icon.contentTintColor = Theme.accent

        let title = NSTextField(labelWithString: "拖入视频开始播放")
        title.font = Theme.display(26, .heavy)
        title.textColor = Theme.textPrimary

        let subtitle = NSTextField(labelWithString: "⌘O 打开文件  ·  ⌘L 打开视频库")
        subtitle.font = .systemFont(ofSize: 14, weight: .medium)
        subtitle.textColor = Theme.textSecondary

        let chips = NSStackView(views: [
            Theme.chip("按住画面  2× 加速", color: Theme.textPrimary),
            Theme.chip("按住左右拖  调速 0.5–6×", color: Theme.textPrimary),
            Theme.chip("B  打星标", color: Theme.star),
        ])
        chips.spacing = 8
        for case let c as NSTextField in chips.views { c.font = .systemFont(ofSize: 12, weight: .bold) }

        let stack = NSStackView(views: [icon, title, subtitle, chips])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(18, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
