import AppKit

/// Floats above the controls once a clip is marked with C: the stretch and its
/// length, then [GIF] [视频] [拷贝] [循环预览] [×]. One click exports; no dialog.
final class ClipBar: NSView {
    enum Action: Int { case gif, video, copy, loop, close }

    var onAction: ((Action) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var buttons: [Action: NSButton] = [:]
    private var titles: [Action: String] = [:]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = Theme.radiusCard
        layer?.borderWidth = 1
        layer?.borderColor = Theme.accent2.withAlphaComponent(0.6).cgColor
        isHidden = true

        label.textColor = Theme.textPrimary
        label.font = Theme.digits(13, .bold)

        let specs: [(Action, String, Bool, String)] = [
            (.gif, L("GIF"), true, "photo.on.rectangle"),
            (.video, L("视频"), true, "film"),
            (.copy, L("拷贝"), false, "doc.on.doc"),
            (.loop, L("循环预览"), false, "repeat"),
            (.close, "", false, "xmark"),
        ]
        var views: [NSView] = [label]
        for (action, title, primary, symbol) in specs {
            let b = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            LibraryOfferBar.style(b, primary: primary, symbol: symbol)
            b.tag = action.rawValue
            b.refusesFirstResponder = true                  // keys keep going to the player
            buttons[action] = b
            titles[action] = title
            views.append(b)
        }
        buttons[.close]?.toolTip = L("取消片段选择")

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        stack.setViews(views, in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var textForTesting: String { label.stringValue }
    func isEnabled(_ action: Action) -> Bool { buttons[action]?.isEnabled ?? false }
    func title(of action: Action) -> String { titles[action] ?? "" }

    /// Changes a button's words, keeping the style LibraryOfferBar.style gave it.
    private func setTitle(_ title: String, of action: Action) {
        guard let b = buttons[action], titles[action] != title else { return }
        titles[action] = title
        let attrs = b.attributedTitle.attributes(at: 0, effectiveRange: nil)
        b.attributedTitle = NSAttributedString(string: " \(title)   ", attributes: attrs)
    }

    /// GIFs are capped (ClipExporter.maxGIFLength): longer clips offer video only.
    func show(_ range: ClipRange) {
        let (a, b) = range.fieldTexts
        let gifOK = range.length <= ClipExporter.maxGIFLength
        let limit = String(Int(ClipExporter.maxGIFLength))
        // Say what Copy will give, and why there is no GIF (asked 2026-10-20: "拷贝后没有 GIF").
        label.stringValue = L("片段 %1$@ – %2$@ · %3$@ 秒", a, b, String(Int(range.length.rounded())))
            + (gifOK ? "" : " · " + L("超过 %@ 秒，只能导出视频", limit))
        setTitle(gifOK ? L("拷贝 GIF") : L("拷贝视频"), of: .copy)
        buttons[.gif]?.isEnabled = gifOK
        buttons[.gif]?.alphaValue = gifOK ? 1 : 0.4
        buttons[.gif]?.toolTip = gifOK ? nil : L("动图最长 %@ 秒", String(Int(ClipExporter.maxGIFLength)))
        isHidden = false
    }

    func hide() { isHidden = true }

    /// Same as clicking the button (tests use this).
    func press(_ action: Action) { onAction?(action) }

    @objc private func pressed(_ sender: NSButton) { Action(rawValue: sender.tag).map(press) }
}
