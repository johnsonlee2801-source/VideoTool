import AppKit

/// Two compact lines inside Recent; never opens a second library window.
final class ContinueWatchingBar: NSView {
    let resumeButton = NSButton(title: L("继续"), target: nil, action: nil)
    let restartButton = NSButton(title: L("从头播放"), target: nil, action: nil)
    private let title = NSTextField(labelWithString: "")
    private(set) var item: ContinueWatchingItem?
    var onOpen: ((ContinueWatchingItem, Bool) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingMiddle
        title.font = Theme.display(12, .medium); title.textColor = Theme.textPrimary
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [resumeButton, restartButton]); buttons.spacing = 12
        let stack = NSStackView(views: [title, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            title.widthAnchor.constraint(equalTo: widthAnchor),
        ])
        for button in [resumeButton, restartButton] {
            button.isBordered = false; button.contentTintColor = Theme.accent
            button.font = Theme.display(12, .semibold); button.target = self; button.action = #selector(pressed(_:))
        }
        restartButton.tag = 1
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func update(_ item: ContinueWatchingItem?) {
        self.item = item; isHidden = item == nil
        title.stringValue = item.map { L("继续观看：%1$@ · %2$@", $0.title, TimeFormatting.string($0.position)) } ?? ""
        title.toolTip = title.stringValue
    }
    @objc private func pressed(_ sender: NSButton) { if let item { onOpen?(item, sender.tag == 1) } }
}
