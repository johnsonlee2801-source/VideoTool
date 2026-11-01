import AppKit

/// A retained, on-demand sidebar view. Search and arrow keys belong here.
final class SubtitleTranscriptView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let table = NSTableView()
    let sourcePopup = NSPopUpButton()
    let replayButton = NSButton(title: L("重听上一句"), target: nil, action: nil)
    let refreshButton = NSButton(title: L("重新读取"), target: nil, action: nil)
    let cancelButton = NSButton(title: L("取消"), target: nil, action: nil)
    let backButton = NSButton(title: L("返回"), target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private var position = 0.0
    private var baseStatus = ""
    private var searchGeneration = 0
    private(set) var isSearching = false
    var searcher: SubtitleSearching = SubtitleSearch() {
        didSet { oldValue.cancel(); searchGeneration += 1 }
    }
    private(set) var document: SubtitleTranscript?
    private(set) var rows: [Int] = []
    var onJump: ((SubtitleCue) -> Void)?
    var onReplay: (() -> Void)?
    var onSource: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onCancel: (() -> Void)?
    var onBack: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: L("字幕搜索")); title.font = Theme.display(16, .bold); title.textColor = Theme.textPrimary
        let header = NSStackView(views: [title, NSView(), backButton]); header.spacing = 8
        sourcePopup.target = self; sourcePopup.action = #selector(sourceChanged(_:))
        sourcePopup.setAccessibilityLabel(L("字幕来源"))
        searchField.placeholderString = L("搜索原文或译文"); searchField.delegate = self
        for button in [replayButton, refreshButton, cancelButton, backButton] {
            button.isBordered = false; button.font = Theme.display(11, .semibold); button.contentTintColor = Theme.accent
            button.target = self
        }
        replayButton.action = #selector(replay(_:)); refreshButton.action = #selector(refresh(_:))
        cancelButton.action = #selector(cancel(_:)); backButton.action = #selector(back(_:))
        replayButton.isEnabled = false; cancelButton.isHidden = true
        let actions = NSStackView(views: [replayButton, refreshButton, cancelButton]); actions.spacing = 10
        status.font = Theme.display(11); status.textColor = Theme.textSecondary; status.maximumNumberOfLines = 3
        table.addTableColumn(NSTableColumn(identifier: .init("cue"))); table.headerView = nil
        table.rowHeight = 82; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = Theme.bg1; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(activate(_:)); table.doubleAction = #selector(activate(_:))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        for view in [header, sourcePopup, searchField, actions, status, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6), header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sourcePopup.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6), sourcePopup.leadingAnchor.constraint(equalTo: header.leadingAnchor), sourcePopup.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: sourcePopup.bottomAnchor, constant: 6), searchField.leadingAnchor.constraint(equalTo: header.leadingAnchor), searchField.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6), actions.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            status.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 5), status.leadingAnchor.constraint(equalTo: header.leadingAnchor), status.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    var selectedSourceID: String? { sourcePopup.selectedItem?.representedObject as? String }
    func setSources(_ sources: [SubtitleSourceOption], selected: String? = nil) {
        sourcePopup.removeAllItems()
        for source in sources { sourcePopup.addItem(withTitle: source.title); sourcePopup.lastItem?.representedObject = source.id }
        if let selected, let item = sourcePopup.itemArray.first(where: { $0.representedObject as? String == selected }) { sourcePopup.select(item) }
        sourcePopup.isEnabled = !sources.isEmpty
    }
    func setDocument(_ document: SubtitleTranscript?, status: String) {
        self.document = document; baseStatus = status
        cancelButton.isHidden = true; refreshButton.isEnabled = true
        table.deselectAll(nil); refreshQuery(); updatePosition(position)
    }
    func setStatus(_ message: String, loading: Bool) {
        baseStatus = message; status.stringValue = message
        cancelButton.isHidden = !loading; refreshButton.isEnabled = !loading
    }
    func updatePosition(_ position: Double) {
        self.position = position.isFinite ? position : 0
        replayButton.isEnabled = document?.replayIndex(at: self.position) != nil
    }
    func refreshQuery() {
        searchGeneration += 1; searcher.cancel()
        let token = searchGeneration, query = searchField.stringValue
        table.deselectAll(nil)
        guard let document else {
            isSearching = false; rows = []; table.reloadData(); status.stringValue = baseStatus; return
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isSearching = false; rows = Array(document.cues.indices.prefix(1000))
            table.reloadData(); status.stringValue = baseStatus; return
        }
        isSearching = true; rows = []; table.reloadData(); status.stringValue = L("正在搜索字幕…")
        searcher.search(document, query: query) { [weak self] matches in
            guard let self, self.searchGeneration == token else { return }
            self.isSearching = false; self.rows = matches; self.table.reloadData()
            self.status.stringValue = matches.count == 1000 ? L("显示前 1000 条结果，请缩小搜索范围") : L("匹配 %@ 句", String(matches.count))
        }
    }
    deinit { searcher.cancel() }
    func controlTextDidChange(_ obj: Notification) { refreshQuery() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let document else { return nil }
        let id = NSUserInterfaceItemIdentifier("TranscriptCueRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TranscriptCueRow) ?? TranscriptCueRow()
        cell.identifier = id; cell.configure(document.cues[rows[row]])
        return cell
    }
    @objc private func activate(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row), let document else { return }
        onJump?(document.cues[rows[row]])
    }
    @objc private func sourceChanged(_ sender: Any?) { if let id = selectedSourceID { onSource?(id) } }
    @objc private func replay(_ sender: Any?) { onReplay?() }
    @objc private func refresh(_ sender: Any?) { onRefresh?() }
    @objc private func cancel(_ sender: Any?) { onCancel?() }
    @objc private func back(_ sender: Any?) { onBack?() }
}

private final class TranscriptCueRow: NSTableCellView {
    private let time = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        time.font = Theme.digits(10, .medium); time.textColor = Theme.accent2
        text.font = Theme.display(12); text.textColor = Theme.textPrimary; text.maximumNumberOfLines = 3
        for child in [time, text] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), time.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), text.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 2), text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func configure(_ cue: SubtitleCue) {
        time.stringValue = TimeFormatting.string(cue.start)
        text.stringValue = [cue.text, cue.translation].compactMap { $0 }.joined(separator: "\n")
        toolTip = text.stringValue
    }
}
