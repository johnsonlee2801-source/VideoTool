import AppKit

/// The library window: grouping modes and folders on the left, a thumbnail grid
/// on the right. Organising is virtual; nothing on disk is moved or renamed.
final class LibraryWindowController: NSWindowController, NSWindowDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    private let controller: LibraryController
    private let onOpen: (URL) -> Void
    private var sections: [LibrarySection] = []

    private let sidebar = NSTableView()
    private let grid = NSCollectionView()
    private let searchField = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: "添加文件夹…", target: nil, action: nil)
    private let rescanButton = NSButton(title: "重新扫描", target: nil, action: nil)

    private enum SidebarRow { case header(String), mode(LibraryGroupingMode), root(String) }
    private var sidebarRows: [SidebarRow] = []

    init(controller: LibraryController, onOpen: @escaping (URL) -> Void) {
        self.controller = controller
        self.onOpen = onOpen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "视频库"
        window.minSize = NSSize(width: 720, height: 420)
        window.setFrameAutosaveName("VideoTool.LibraryWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onProgress = { [weak self] in self?.refreshStatus() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }

        let col = NSTableColumn(identifier: .init("side"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 26
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideMenu = NSMenu()
        sideMenu.delegate = self
        sidebar.menu = sideMenu
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 200, height: 168)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 8, left: 16, bottom: 18, right: 16)
        layout.headerReferenceSize = NSSize(width: 100, height: 34)
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.backgroundColors = [NSColor(white: 0.08, alpha: 1)]
        grid.register(LibraryCardItem.self, forItemWithIdentifier: LibraryCardItem.id)
        grid.register(LibrarySectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                      withIdentifier: LibrarySectionHeader.id)
        let gridMenu = NSMenu()
        gridMenu.delegate = self
        grid.menu = gridMenu
        let gridScroll = NSScrollView()
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true

        searchField.placeholderString = "搜索文件名或标签"
        searchField.delegate = self
        addButton.target = self; addButton.action = #selector(addFolder(_:))
        rescanButton.target = self; rescanButton.action = #selector(rescan(_:))
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 14)

        let bar = NSStackView(views: [addButton, rescanButton, status, NSView(), searchField])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        for v in [bar, sideScroll, gridScroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 240),
            sideScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sideScroll.widthAnchor.constraint(equalToConstant: 210),
            gridScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            empty.widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    // MARK: refresh

    /// Cheap: status line only (called while scanning).
    private func refreshStatus() {
        status.stringValue = controller.notice.map { "\($0)  ·  \(controller.statusText)" } ?? controller.statusText
    }

    private func refresh() {
        sidebarRows = [.header("整理方式")] + LibraryGroupingMode.allCases.map { .mode($0) }
            + [.header("文件夹")] + controller.roots.map { .root($0) }
        sidebar.reloadData()
        if let i = sidebarRows.firstIndex(where: { if case .mode(let m) = $0 { return m == controller.mode }; return false }) {
            sidebar.selectRowIndexes([i], byExtendingSelection: false)
        }
        sections = controller.sections
        grid.reloadData()
        refreshStatus()
        rescanButton.isEnabled = !controller.roots.isEmpty && !controller.isIndexing
        if controller.roots.isEmpty {
            empty.stringValue = "还没有视频文件夹。\n点「添加文件夹…」选一个放视频的文件夹，VideoTool 会自动整理（只建索引，不会移动你的文件）。"
        } else if sections.isEmpty {
            empty.stringValue = controller.isIndexing ? "正在扫描…" :
                (controller.mode == .duplicates && controller.search.isEmpty ? "没有发现重复文件。" : "没有符合条件的视频。")
        } else {
            empty.stringValue = ""
        }
        empty.isHidden = empty.stringValue.isEmpty
    }

    // MARK: actions

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加到视频库"
        panel.message = "选择放视频的文件夹。VideoTool 只读取、建索引，不会移动或修改文件。"
        guard let window, panel.runModal() == .OK else { _ = window; return }
        for url in panel.urls { controller.addRoot(url.path) }
    }

    @objc private func rescan(_ sender: Any?) { controller.rescanAll() }

    func controlTextDidChange(_ obj: Notification) { controller.search = searchField.stringValue }

    private func item(at indexPath: IndexPath) -> LibraryItem? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    fileprivate func open(_ item: LibraryItem) { onOpen(URL(fileURLWithPath: item.record.path)) }

    // Test hooks (the grid's real double-click goes through LibraryCardItem).
    func openForTesting(section: Int, item index: Int) {
        if let item = item(at: IndexPath(item: index, section: section)) { open(item) }
    }
    var emptyMessageForTesting: String { empty.stringValue }

    // MARK: sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        switch sidebarRows[row] {
        case .header(let t):
            label.stringValue = t
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
        case .mode(let m):
            label.stringValue = m.title
        case .root(let p):
            label.stringValue = "📁 " + (p as NSString).lastPathComponent
            label.toolTip = p
        }
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = sidebarRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .mode = sidebarRows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard sidebarRows.indices.contains(row), case .mode(let m) = sidebarRows[row], m != controller.mode else { return }
        controller.mode = m
    }

    // MARK: context menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === sidebar.menu {
            let row = sidebar.clickedRow
            guard sidebarRows.indices.contains(row), case .root(let path) = sidebarRows[row] else { return }
            menu.addItem(ClosureMenuItem("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) })
            menu.addItem(ClosureMenuItem("从视频库移除（不删除文件）") { [weak self] in self?.controller.removeRoot(path) })
        } else if menu === grid.menu {
            let point = grid.convert(grid.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            guard let ip = grid.indexPathForItem(at: point), let item = item(at: ip) else { return }
            menu.addItem(ClosureMenuItem("在播放器中打开") { [weak self] in self?.open(item) })
            menu.addItem(ClosureMenuItem("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.record.path)])
            })
        }
    }

    // MARK: grid

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: LibraryCardItem.id, for: indexPath)
        if let card = cell as? LibraryCardItem, let item = item(at: indexPath) {
            card.configure(item, thumbnail: controller.thumbnailURL(for: item))
            card.onDoubleClick = { [weak self] in self?.open(item) }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: LibrarySectionHeader.id, for: indexPath)
        (view as? LibrarySectionHeader)?.label.stringValue =
            "\(sections[indexPath.section].title)  ·  \(sections[indexPath.section].items.count)"
        return view
    }

    // MARK: window

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        controller.rescanAll()          // incremental: unchanged files are skipped
    }

    func windowWillClose(_ notification: Notification) { controller.cancelScan() }
}

/// A thumbnail card: image, name, duration, star count and the first tags.
final class LibraryCardItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("LibraryCard")
    var onDoubleClick: (() -> Void)?

    private let thumb = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 168))
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.black.cgColor
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor.white.withAlphaComponent(0.6)
        detail.lineBreakMode = .byTruncatingTail
        for s in [thumb, nameLabel, detail] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: v.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            thumb.heightAnchor.constraint(equalToConstant: 112),
            nameLabel.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
        ])
        view = v
    }

    func configure(_ item: LibraryItem, thumbnail: URL) {
        nameLabel.stringValue = item.name
        nameLabel.toolTip = item.record.path
        var bits: [String] = []
        if item.record.duration > 0 { bits.append(TimeFormatting.string(item.record.duration)) }
        let res = LibraryGrouping.resolutionBucket(width: item.record.width, height: item.record.height)
        if res != .unknown { bits.append(res.title) }
        if item.starCount > 0 { bits.append("★\(item.starCount)") }
        bits += item.tags.prefix(2)
        detail.stringValue = bits.joined(separator: " · ")
        thumb.image = NSImage(contentsOf: thumbnail) ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
    }

    override var isSelected: Bool {
        didSet { view.layer?.borderWidth = isSelected ? 2 : 0; view.layer?.borderColor = NSColor.systemYellow.cgColor }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

final class LibrarySectionHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("LibraryHeader")
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                                     label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Menu item that runs a closure (keeps context menus compact).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not supported") }
    @objc private func run() { handler() }
}
