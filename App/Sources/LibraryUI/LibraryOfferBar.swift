import AppKit

/// Small floating card over the video: "Add «folder» to the library?"
/// [加入] [不加] [不再询问]; after adding, a confirmation with [打开视频库].
/// Hides itself if left alone, so it never stays in the way of the picture.
final class LibraryOfferBar: NSView {
    enum Action: Int { case add, decline, neverAsk, openLibrary }

    static let offerSeconds: TimeInterval = 15
    static let confirmSeconds: TimeInterval = 6

    /// Returns whether the folder was added (a database error: false).
    var onAdd: ((LibraryOffer.Proposal) -> Bool)?
    var onDecline: ((String) -> Void)?
    var onNeverAsk: (() -> Void)?
    var onOpenLibrary: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let addButton = NSButton(title: L("加入"), target: nil, action: nil)
    private let declineButton = NSButton(title: L("不加"), target: nil, action: nil)
    private let neverButton = NSButton(title: L("不再询问"), target: nil, action: nil)
    private let openButton = NSButton(title: L("打开视频库"), target: nil, action: nil)
    private var proposal: LibraryOffer.Proposal?
    private var hideTimer: Timer?

    var message: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = Theme.radiusCard
        layer?.borderWidth = 1
        layer?.borderColor = Theme.stroke.cgColor
        isHidden = true

        label.textColor = Theme.textPrimary
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, primary, symbol, action) in [(addButton, true, "plus", Action.add),
                                                  (declineButton, false, "xmark", .decline),
                                                  (neverButton, false, "bell.slash", .neverAsk),
                                                  (openButton, true, "square.grid.2x2", .openLibrary)] {
            Self.style(button, primary: primary, symbol: symbol)
            button.tag = action.rawValue
            button.target = self
            button.action = #selector(buttonPressed(_:))
            button.refusesFirstResponder = true          // keys keep going to the player
        }

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var textForTesting: String { label.stringValue }

    func offer(_ proposal: LibraryOffer.Proposal) {
        self.proposal = proposal
        let name = Self.name(proposal.path)
        label.stringValue = proposal.wholeFolder
            ? L("把「%@」加入视频库？自动整理里面的视频", String(describing: name))
            : L("把「%@」里的视频加入视频库？只整理这一层，不含子文件夹", String(describing: name))
        label.toolTip = proposal.path
        show([label, addButton, declineButton, neverButton], for: Self.offerSeconds)
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        isHidden = true
        proposal = nil
    }

    /// Same as clicking the button (tests use this).
    func press(_ action: Action) {
        switch action {
        case .add:
            guard let proposal else { return }
            // Confirm only what happened: a failed add says so (audit 2026-10-20).
            guard onAdd?(proposal) ?? false else {
                label.stringValue = L("没能加入视频库")
                show([label], for: Self.confirmSeconds)
                return
            }
            label.stringValue = L("已加入「%@」，正在后台整理", String(describing: Self.name(proposal.path)))
            show([label, openButton], for: Self.confirmSeconds)
        case .decline:
            if let proposal { onDecline?(proposal.path) }
            hide()
        case .neverAsk:
            onNeverAsk?()
            hide()
        case .openLibrary:
            onOpenLibrary?()
            hide()
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        Action(rawValue: sender.tag).map(press)
    }

    private func show(_ views: [NSView], for seconds: TimeInterval) {
        stack.setViews(views, in: .leading)
        isHidden = false
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
    }

    /// Compact version of the library window's buttons: sized to their label.
    static func style(_ button: NSButton, primary: Bool, symbol: String) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Theme.radiusSmall + 1
        button.layer?.backgroundColor = (primary ? Theme.accent : Theme.bg2).cgColor
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 11, weight: .heavy)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = primary ? .white : Theme.textPrimary
        button.attributedTitle = NSAttributedString(string: " \(button.title)   ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: primary ? NSColor.white : Theme.textPrimary])
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private static func name(_ folder: String) -> String { (folder as NSString).lastPathComponent }
}
