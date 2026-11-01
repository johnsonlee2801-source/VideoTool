import AppKit

/// Network records have their own source and actions, not synthetic local paths.
final class NetworkHistoryView: NSView {
    private let rows = NetworkHistoryStack()
    private let scroll = NSScrollView()
    private let store: NetworkWatchHistoryStore
    private let onOpen: (NetworkWatchEntry, Bool) -> Void
    private(set) var entries: [NetworkWatchEntry] = []
    private(set) var playButtons: [NSButton] = []
    init(store: NetworkWatchHistoryStore, onOpen: @escaping (NetworkWatchEntry, Bool) -> Void) {
        self.store = store; self.onOpen = onOpen
        super.init(frame: .zero)
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func refresh(search: String) {
        let origin = scroll.contentView.bounds.origin
        entries = store.entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.video.id.localizedCaseInsensitiveContains(search) }
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        playButtons = []
        for entry in entries {
            let title = NSButton(title: entry.title, target: self, action: #selector(play(_:)))
            title.identifier = .init(entry.video.key); title.isBordered = false; title.alignment = .left; title.lineBreakMode = .byTruncatingTail
            title.contentTintColor = Theme.textPrimary; title.font = Theme.display(12, .semibold); title.toolTip = entry.title
            playButtons.append(title)
            let detail = NSTextField(labelWithString: (entry.video.site == .youtube ? "YouTube" : "Bilibili · P\(entry.video.page)") + " · " + TimeFormatting.string(entry.position))
            detail.font = Theme.display(11); detail.textColor = Theme.textSecondary
            let restart = NSButton(title: L("从头播放"), target: self, action: #selector(restart(_:)))
            let remove = NSButton(title: L("移除记录"), target: self, action: #selector(remove(_:)))
            for button in [restart, remove] { button.identifier = .init(entry.video.key); button.isBordered = false; button.font = Theme.display(11); button.contentTintColor = Theme.accent }
            let actions = NSStackView(views: [restart, remove]); actions.spacing = 12
            let row = NSStackView(views: [title, detail, actions]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 2
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            title.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        if entries.isEmpty {
            let label = NSTextField(wrappingLabelWithString: L("还没有网络播放记录"))
            label.font = Theme.display(12); label.textColor = Theme.textSecondary
            rows.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        rows.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func entry(_ sender: NSButton) -> NetworkWatchEntry? { entries.first { $0.video.key == sender.identifier?.rawValue } }
    @objc private func play(_ sender: NSButton) { if let entry = entry(sender) { onOpen(entry, false) } }
    @objc private func restart(_ sender: NSButton) { if let entry = entry(sender) { onOpen(entry, true) } }
    @objc private func remove(_ sender: NSButton) { if let entry = entry(sender) { store.remove(entry.video.key) } }
}

private final class NetworkHistoryStack: NSStackView { override var isFlipped: Bool { true } }
