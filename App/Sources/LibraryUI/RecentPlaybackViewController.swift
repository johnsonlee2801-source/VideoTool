import AppKit

final class RecentPlaybackViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let history: WatchHistoryStore
    private let index: () -> [LibraryItem]
    private let thumbnail: (LibraryItem) -> URL?
    private var selectedSource = 0
    private var sourceQueries = ["", ""]
    private let onOpen: (URL) -> Void
    private let networkHistory: NetworkWatchHistoryStore?
    private let onOpenNetwork: ((NetworkWatchEntry, Bool) -> Void)?
    let sourceSelector = NSSegmentedControl(labels: [L("本地"), L("网络")], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var networkView: NetworkHistoryView?
    private(set) var rows: [RecentPlaybackItem] = []
    let searchField = NSSearchField()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: L("还没有播放记录"))
    var currentPath: String? { didSet { if currentPath != oldValue { refresh() } } }

    init(history: WatchHistoryStore, index: @escaping () -> [LibraryItem],
         thumbnail: @escaping (LibraryItem) -> URL?, onOpen: @escaping (URL) -> Void,
         networkHistory: NetworkWatchHistoryStore? = nil, onOpenNetwork: ((NetworkWatchEntry, Bool) -> Void)? = nil) {
        self.networkHistory = networkHistory; self.onOpenNetwork = onOpenNetwork
        self.history = history; self.index = index; self.thumbnail = thumbnail; self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
        view = NSView()
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    private func build() {
        searchField.placeholderString = L("搜索文件名或标签")
        searchField.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("recent")))
        table.headerView = nil
        table.rowHeight = 96
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.backgroundColor = Theme.bg1
        table.selectionHighlightStyle = .none
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelection(_:))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.font = .systemFont(ofSize: 13, weight: .medium)
        empty.textColor = Theme.textSecondary; empty.alignment = .center
        sourceSelector.selectedSegment = 0; sourceSelector.target = self; sourceSelector.action = #selector(sourceChanged(_:))
        sourceSelector.isHidden = networkHistory == nil
        if let networkHistory {
            let network = NetworkHistoryView(store: networkHistory) { [weak self] in self?.onOpenNetwork?($0, $1) }
            networkView = network
            network.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(network)
            view.addSubview(searchField)
            NSLayoutConstraint.activate([
                network.leadingAnchor.constraint(equalTo: view.leadingAnchor), network.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                network.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12), network.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        for child in [sourceSelector, searchField, scroll, empty] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            sourceSelector.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            sourceSelector.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            sourceSelector.heightAnchor.constraint(equalToConstant: networkHistory == nil ? 0 : 24),
            searchField.topAnchor.constraint(equalTo: sourceSelector.bottomAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
    @objc private func sourceChanged(_ sender: Any?) {
        sourceQueries[selectedSource] = searchField.stringValue
        selectedSource = max(0, min(1, sourceSelector.selectedSegment))
        searchField.stringValue = sourceQueries[selectedSource]
        refresh()
    }
    func refresh() {
        let network = sourceSelector.selectedSegment == 1 && networkView != nil
        networkView?.isHidden = !network; scroll.isHidden = network
        searchField.placeholderString = network ? L("搜索网络视频标题") : L("搜索文件名或标签")
        if network { networkView?.refresh(search: searchField.stringValue); empty.isHidden = true; return }
        let selectedPath = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].path : nil
        let origin = scroll.contentView.bounds.origin
        rows = RecentPlayback.items(history: history.all, indexed: index(), search: searchField.stringValue)
        table.reloadData()
        if let selectedPath, let row = rows.firstIndex(where: { $0.path == selectedPath }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        empty.stringValue = searchField.stringValue.isEmpty ? L("还没有播放记录") : L("没有符合条件的视频")
        empty.isHidden = !rows.isEmpty
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("RecentPlaybackRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarMediaRow) ?? SidebarMediaRow()
        cell.identifier = id
        let record = rows[row]
        cell.configure(path: record.path, item: record.indexed, watch: record.watch,
                       thumbnail: record.indexed.flatMap(thumbnail), recent: true, current: record.path == currentPath)
        return cell
    }
    @objc private func openSelection(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        onOpen(URL(fileURLWithPath: rows[row].path))
    }
}
