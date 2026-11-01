import AppKit

private final class LibraryLayoutView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

private final class LibraryFlowLayout: NSCollectionViewFlowLayout {
    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if let collectionView, newBounds.width != collectionView.bounds.width,
           let flow = context as? NSCollectionViewFlowLayoutInvalidationContext {
            // Native flow invalidation otherwise keeps the old delegate widths
            // while the sidebar is shrinking, producing transient overflow.
            flow.invalidateFlowLayoutDelegateMetrics = true
        }
        return context
    }
}

/// Reusable library content. Its host owns the window and indexing lifetime.
/// Organising is virtual; nothing on disk is moved or renamed.
class LibraryBrowserViewController: NSViewController,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    private let controller: LibraryController
    private let onOpen: (URL) -> Void
    private var sections: [LibrarySection] = []
    private(set) var folderBrowser: FolderBrowserViewController?
    private var foldersVisible = true
    private var legacyBar: NSView?

    private let sidebar = NSTableView()
    private let grid = NSCollectionView()
    private let gridScroll = NSScrollView()
    private let modePicker = NSPopUpButton()
    private let folderPicker = NSPopUpButton()
    private let folderManager = NSButton()
    private var sideWidth: NSLayoutConstraint?
    private var lastLayoutWidth: CGFloat = -1
    private(set) var selectedRoot: String?
    var onItemsChange: (() -> Void)?
    var currentPath: String? { didSet { folderBrowser?.currentPath = currentPath; if oldValue != currentPath { reloadVisibleCards() } } }
    var window: NSWindow? { view.window }
    var gridForTesting: NSCollectionView { grid }
    private let searchField = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "film.stack.fill", accessibilityDescription: nil)!)
    private let emptyTitle = NSTextField(labelWithString: "")
    private lazy var emptyStack: NSStackView = {
        let s = NSStackView(views: [emptyIcon, emptyTitle, empty])
        s.orientation = .vertical
        s.spacing = 12
        return s
    }()
    private let addButton = NSButton(title: L("添加文件夹…"), target: nil, action: nil)
    private let rescanButton = NSButton(title: L("重新扫描"), target: nil, action: nil)

    private enum SidebarRow { case header(String), mode(LibraryGroupingMode), root(String) }
    private var sidebarRows: [SidebarRow] = []

    init(controller: LibraryController, onOpen: @escaping (URL) -> Void) {
        self.controller = controller
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
        let root = LibraryLayoutView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.onLayout = { [weak self] in self?.updateLayout() }
        view = root
        build()
        let folders = FolderBrowserViewController(controller: controller, onOpen: onOpen)
        folderBrowser = folders
        folders.onShowAdvanced = { [weak self] in self?.showFolderBrowsing(false) }
        addChild(folders)
        folders.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(folders.view)
        NSLayoutConstraint.activate([folders.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), folders.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), folders.view.topAnchor.constraint(equalTo: view.topAnchor), folders.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        controller.onChange = { [weak self] in self?.refresh(); self?.onItemsChange?() }
        controller.onProgress = { [weak self] in self?.refreshStatus() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: layout

    private func build() {
        let content = view
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg0.cgColor

        let col = NSTableColumn(identifier: .init("side"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .plain
        sidebar.backgroundColor = Theme.bg1
        sidebar.rowHeight = 34
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.selectionHighlightStyle = .regular
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideMenu = NSMenu()
        sideMenu.delegate = self
        sidebar.menu = sideMenu
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = true
        sideScroll.backgroundColor = Theme.bg1
        sideScroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        let layout = LibraryFlowLayout()
        layout.itemSize = LibraryCardItem.layout(forWidth: 1000).itemSize
        layout.minimumInteritemSpacing = LibraryCardItem.spacing
        layout.minimumLineSpacing = 22
        layout.sectionInset = NSEdgeInsets(top: 6, left: LibraryCardItem.sideInset, bottom: 26, right: LibraryCardItem.sideInset)
        layout.headerReferenceSize = NSSize(width: 100, height: 44)
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.backgroundColors = [Theme.bg0]
        grid.register(LibraryCardItem.self, forItemWithIdentifier: LibraryCardItem.id)
        grid.register(SidebarMediaItem.self, forItemWithIdentifier: SidebarMediaItem.id)
        grid.register(LibrarySectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                      withIdentifier: LibrarySectionHeader.id)
        let gridMenu = NSMenu()
        gridMenu.delegate = self
        grid.menu = gridMenu
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.backgroundColor = Theme.bg0

        searchField.placeholderString = L("搜索文件名或标签")
        searchField.delegate = self
        searchField.controlSize = .large
        addButton.target = self; addButton.action = #selector(addFolder(_:))
        rescanButton.target = self; rescanButton.action = #selector(rescan(_:))
        Self.style(addButton, primary: true, symbol: "plus")
        Self.style(rescanButton, primary: false, symbol: "arrow.clockwise")
        status.textColor = Theme.textSecondary
        status.font = .systemFont(ofSize: 12, weight: .medium)
        empty.alignment = .center
        empty.textColor = Theme.textSecondary
        empty.font = .systemFont(ofSize: 14, weight: .semibold)
        emptyIcon.symbolConfiguration = .init(pointSize: 46, weight: .bold)
        emptyIcon.contentTintColor = Theme.accent
        emptyTitle.font = Theme.display(24, .heavy)
        emptyTitle.textColor = Theme.textPrimary
        emptyTitle.alignment = .center

        modePicker.addItems(withTitles: LibraryGroupingMode.allCases.map(\.title))
        modePicker.target = self; modePicker.action = #selector(modeChanged(_:))
        modePicker.font = .systemFont(ofSize: 12, weight: .semibold)
        folderPicker.target = self; folderPicker.action = #selector(folderChanged(_:))
        folderPicker.font = .systemFont(ofSize: 12, weight: .medium)
        modePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let filters = NSStackView(views: [modePicker, folderPicker])
        filters.distribution = .fillEqually
        filters.spacing = 6
        rescanButton.title = ""
        rescanButton.attributedTitle = NSAttributedString(string: "")
        rescanButton.toolTip = L("重新扫描")
        folderManager.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L("文件夹"))
        folderManager.isBordered = false
        folderManager.contentTintColor = Theme.textSecondary
        folderManager.target = self; folderManager.action = #selector(showFolderMenu(_:))
        let backToFolders = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: L("返回文件夹浏览"))!, target: self, action: #selector(showFolders(_:)))
        backToFolders.isBordered = false; backToFolders.contentTintColor = Theme.accent2; backToFolders.toolTip = L("返回文件夹浏览")
        backToFolders.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let actions = NSStackView(views: [addButton, NSView(), backToFolders, rescanButton, folderManager])
        actions.spacing = 8
        let bar = NSStackView(views: [searchField, filters, actions, status])
        legacyBar = bar
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        searchField.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -28).isActive = true
        filters.widthAnchor.constraint(equalTo: searchField.widthAnchor).isActive = true
        actions.widthAnchor.constraint(equalTo: searchField.widthAnchor).isActive = true
        status.lineBreakMode = .byTruncatingTail
        status.widthAnchor.constraint(equalTo: searchField.widthAnchor).isActive = true
        emptyTitle.font = Theme.display(18, .heavy)
        empty.font = .systemFont(ofSize: 12, weight: .medium)
        for v in [bar, sideScroll, gridScroll, emptyStack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let sideWidth = sideScroll.widthAnchor.constraint(equalToConstant: 0)
        self.sideWidth = sideWidth
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sideScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sideWidth,
            gridScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: gridScroll.widthAnchor, constant: -32),
        ])
    }

    private func updateLayout() {
        guard abs(view.bounds.width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = view.bounds.width
        sideWidth?.constant = view.bounds.width >= 700 ? 180 : 0
        (sidebar.enclosingScrollView)?.isHidden = view.bounds.width < 700
        if let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout {
            let compact = view.bounds.width < 700
            layout.minimumLineSpacing = compact ? 8 : 22
            layout.sectionInset = NSEdgeInsets(top: 6, left: compact ? 10 : 22, bottom: 16, right: compact ? 10 : 22)
            layout.headerReferenceSize = NSSize(width: 100, height: compact ? 32 : 44)
        }
        grid.collectionViewLayout?.invalidateLayout()
        reloadVisibleCards()
        applyBrowsingVisibility()
    }

    func showFolderBrowsing(_ visible: Bool) {
        foldersVisible = visible
        view.window?.makeFirstResponder(nil)
        applyBrowsingVisibility()
    }
    @objc private func showFolders(_ sender: Any?) { showFolderBrowsing(true) }
    private func applyBrowsingVisibility() {
        folderBrowser?.view.isHidden = !foldersVisible
        legacyBar?.isHidden = foldersVisible
        sidebar.enclosingScrollView?.isHidden = foldersVisible || view.bounds.width < 700
        gridScroll.isHidden = foldersVisible
        emptyStack.isHidden = foldersVisible || empty.stringValue.isEmpty
    }

    private func selectedPaths() -> Set<String> {
        Set(grid.selectionIndexPaths.compactMap { item(at: $0)?.record.path })
    }

    private func reloadVisibleCards(keeping selected: Set<String>? = nil) {
        guard grid.bounds.width > 20 else { return }
        let selected = selected ?? selectedPaths()
        let origin = gridScroll.contentView.bounds.origin
        grid.reloadData()
        let restored = sections.enumerated().flatMap { section, value in
            value.items.enumerated().compactMap { index, item in
                selected.contains(item.record.path) ? IndexPath(item: index, section: section) : nil
            }
        }
        grid.selectionIndexPaths = Set(restored.prefix(1))
        grid.layoutSubtreeIfNeeded()
        gridScroll.contentView.scroll(to: origin)
        gridScroll.reflectScrolledClipView(gridScroll.contentView)
    }

    @objc private func modeChanged(_ sender: Any?) {
        guard LibraryGroupingMode.allCases.indices.contains(modePicker.indexOfSelectedItem) else { return }
        controller.mode = LibraryGroupingMode.allCases[modePicker.indexOfSelectedItem]
    }
    @objc private func folderChanged(_ sender: Any?) {
        let index = folderPicker.indexOfSelectedItem - 1
        selectedRoot = controller.roots.indices.contains(index) ? controller.roots[index] : nil
        refresh()
    }
    @objc private func showFolderMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for root in controller.roots {
            let sub = NSMenu(title: (root as NSString).lastPathComponent)
            if let row = sidebarRow(root: root) { sidebarMenuItems(row: row).forEach(sub.addItem) }
            menu.addItem(withTitle: sub.title, action: nil, keyEquivalent: "").submenu = sub
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    func refreshFromStore() { controller.reload() }
    func shutdown() { folderBrowser?.shutdown(); controller.onChange = nil; controller.onProgress = nil }

    static func style(_ button: NSButton, primary: Bool, symbol: String) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Theme.radiusSmall + 2
        button.layer?.backgroundColor = (primary ? Theme.accent : Theme.bg2).cgColor
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 12, weight: .heavy)
        button.imagePosition = .imageLeading
        button.contentTintColor = primary ? .white : Theme.textPrimary
        button.attributedTitle = NSAttributedString(string: " " + button.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: primary ? NSColor.white : Theme.textPrimary])
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: primary ? 118 : 28).isActive = true
    }

    // MARK: refresh

    /// Cheap: status line only (called while scanning).
    private func refreshStatus() {
        status.stringValue = controller.notice.map { "\($0)  ·  \(controller.statusText)" } ?? controller.statusText
        status.toolTip = status.stringValue
        folderBrowser?.refreshStatus()
    }

    private func refresh() {
        let selection = selectedPaths()
        sidebarRows = [.header(L("整理方式"))] + LibraryGroupingMode.allCases.map { .mode($0) }
            + [.header(L("文件夹"))] + controller.roots.map { .root($0) }
        sidebar.reloadData()
        if let i = sidebarRows.firstIndex(where: { if case .mode(let m) = $0 { return m == controller.mode }; return false }) {
            sidebar.selectRowIndexes([i], byExtendingSelection: false)
        }
        if let selectedRoot, !controller.roots.contains(selectedRoot) { self.selectedRoot = nil }
        modePicker.selectItem(at: LibraryGroupingMode.allCases.firstIndex(of: controller.mode) ?? 0)
        folderPicker.removeAllItems()
        folderPicker.addItems(withTitles: [L("所有文件夹")] + controller.roots.map { ($0 as NSString).lastPathComponent })
        folderPicker.selectItem(at: selectedRoot.flatMap { controller.roots.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        sections = controller.sections.compactMap { section in
            let items = selectedRoot.map { root in section.items.filter { $0.record.root == root } } ?? section.items
            return items.isEmpty ? nil : LibrarySection(title: section.title, items: items)
        }
        reloadVisibleCards(keeping: selection)
        refreshStatus()
        rescanButton.isEnabled = !controller.roots.isEmpty && !controller.isIndexing
        if controller.roots.isEmpty {
            emptyTitle.stringValue = L("把视频文件夹交给我")
            emptyIcon.image = NSImage(systemSymbolName: "film.stack.fill", accessibilityDescription: nil)
            empty.stringValue = L("点左上角「添加文件夹…」，VideoTool 会按文件夹、日期、时长、清晰度和画面内容自动整理。\n只建索引，不会移动你的文件。")
        } else if sections.isEmpty {
            emptyIcon.image = NSImage(systemSymbolName: controller.isIndexing ? "hourglass" : "sparkle.magnifyingglass",
                                      accessibilityDescription: nil)
            emptyTitle.stringValue = controller.isIndexing ? L("正在扫描…") :
                (controller.mode == .duplicates && controller.search.isEmpty ? L("没有重复文件") : L("没有符合条件的视频"))
            empty.stringValue = controller.isIndexing ? L("视频多的话需要一会儿，可以先去看片。") :
                (controller.mode == .duplicates && controller.search.isEmpty ? L("两份内容完全一样的视频会出现在这里。") : L("换个关键词试试。"))
        } else {
            emptyTitle.stringValue = ""
            empty.stringValue = ""
        }
        emptyStack.isHidden = empty.stringValue.isEmpty
        folderBrowser?.refresh()
        applyBrowsingVisibility()
    }

    // MARK: actions

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("添加到视频库")
        panel.message = L("选择放视频的文件夹。VideoTool 只读取、建索引，不会移动或修改文件。")
        guard window != nil, panel.runModal() == .OK else { return }
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
    func setModeForSnapshot(_ mode: LibraryGroupingMode) { controller.mode = mode }

    // MARK: sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        let selected = tableView.selectedRow == row
        switch sidebarRows[row] {
        case .header(let t):
            label.stringValue = t.uppercased()
            label.font = .systemFont(ofSize: 11, weight: .heavy)
            label.textColor = Theme.textTertiary
            return Self.sidebarCell(icon: nil, label: label, indent: 16)
        case .mode(let m):
            label.stringValue = m.title
            label.font = .systemFont(ofSize: 13, weight: selected ? .heavy : .semibold)
            label.textColor = selected ? Theme.textPrimary : Theme.textSecondary
            return Self.sidebarCell(icon: Self.symbol(for: m), label: label, indent: 12,
                                    tint: selected ? Theme.accent : Theme.textSecondary)
        case .root(let p):
            let shallow = controller.rootEntries.contains { $0.path == p && !$0.recursive }
            label.stringValue = (p as NSString).lastPathComponent + (shallow ? L(" · 仅这一层") : "")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = Theme.textSecondary
            label.toolTip = p
            return Self.sidebarCell(icon: "folder.fill", label: label, indent: 12, tint: Theme.accent2)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    private static func symbol(for mode: LibraryGroupingMode) -> String {
        switch mode {
        case .all: return "square.grid.2x2.fill"
        case .series: return "play.rectangle.on.rectangle.fill"
        case .folder: return "folder.fill"
        case .date: return "calendar"
        case .duration: return "clock.fill"
        case .resolution: return "tv.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .tag: return "tag.fill"
        }
    }

    private static func sidebarCell(icon: String?, label: NSTextField, indent: CGFloat, tint: NSColor = Theme.textSecondary) -> NSView {
        let cell = NSView()
        var views: [NSView] = []
        if let icon {
            let image = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil)!)
            image.symbolConfiguration = .init(pointSize: 13, weight: .bold)
            image.contentTintColor = tint
            image.widthAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(image)
        }
        views.append(label)
        let stack = NSStackView(views: views)
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
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
        sidebar.reloadData(forRowIndexes: IndexSet(integersIn: 0..<sidebarRows.count), columnIndexes: [0])
        let row = sidebar.selectedRow
        guard sidebarRows.indices.contains(row), case .mode(let m) = sidebarRows[row], m != controller.mode else { return }
        controller.mode = m
    }

    // MARK: context menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === sidebar.menu {
            sidebarMenuItems(row: sidebar.clickedRow).forEach(menu.addItem)
        } else if menu === grid.menu {
            let point = grid.convert(grid.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            guard let ip = grid.indexPathForItem(at: point), let item = item(at: ip) else { return }
            cardMenuItems(for: item).forEach(menu.addItem)
        }
    }

    /// Right-click on a folder in the sidebar (nothing for the mode rows).
    func sidebarMenuItems(row: Int) -> [NSMenuItem] {
        guard sidebarRows.indices.contains(row), case .root(let path) = sidebarRows[row] else { return [] }
        return [ClosureMenuItem(L("在 Finder 中显示")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) },
                ClosureMenuItem(L("从视频库移除（不删除文件）")) { [weak self] in self?.controller.removeRoot(path) }]
    }

    /// Right-click on a video card.
    func cardMenuItems(for item: LibraryItem) -> [NSMenuItem] {
        [ClosureMenuItem(L("在播放器中打开")) { [weak self] in self?.open(item) },
         ClosureMenuItem(L("修改剧集信息…")) { [weak self] in self?.editSeries(item) },
         ClosureMenuItem(L("在 Finder 中显示")) {
             NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.record.path)])
         }]
    }

    /// Row of a sidebar entry (tests select modes and folders by it).
    func sidebarRow(mode: LibraryGroupingMode) -> Int? { sidebarRows.firstIndex { if case .mode(mode) = $0 { return true } else { return false } } }
    func sidebarRow(root: String) -> Int? { sidebarRows.firstIndex { if case .root(root) = $0 { return true } else { return false } } }
    var sidebarForTesting: NSTableView { sidebar }
    var searchFieldForTesting: NSSearchField { searchField }
    var emptyMessage: (title: String, detail: String) { (emptyTitle.stringValue, empty.stringValue) }

    /// Back from the player: progress may have changed (继续观看, progress stripes).
    /// Only re-reads the index; no rescan.
    override func viewWillAppear() { super.viewWillAppear(); controller.reload() }

    /// Correct how a file is grouped in 按剧集 (kept by content, survives moves).
    private func editSeries(_ item: LibraryItem) {
        guard let window else { return }
        SeriesEditDialog.run(on: window, item: item, current: controller.episodeInfo(for: item)) { [weak self] result in
            switch result {
            case .save(let override, let renameShow): self?.controller.saveSeries(override, for: item, renameShow: renameShow)
            case .notSeries: self?.controller.saveSeries(SeriesOverride(excluded: true), for: item)
            case .cancel: break
            }
        }
    }

    // MARK: grid

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let compact = view.bounds.width < 700
        let cell = collectionView.makeItem(withIdentifier: compact ? SidebarMediaItem.id : LibraryCardItem.id, for: indexPath)
        if let item = item(at: indexPath) {
            if let card = cell as? LibraryCardItem {
                card.configure(item, thumbnail: controller.thumbnailURL(for: item))
                card.onDoubleClick = { [weak self] in self?.open(item) }
            } else if let card = cell as? SidebarMediaItem {
                card.row.configure(path: item.record.path, item: item, watch: item.watch,
                                   thumbnail: controller.thumbnailURL(for: item), recent: false, current: item.record.path == currentPath)
                card.onDoubleClick = { [weak self] in self?.open(item) }
            }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: LibrarySectionHeader.id, for: indexPath)
        (view as? LibrarySectionHeader)?.set(title: sections[indexPath.section].title,
                                             count: sections[indexPath.section].items.count)
        return view
    }

    /// Cards widen to fill each row (adaptive column count).
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        if view.bounds.width < 700 {
            let insets = (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.sectionInset ?? .init()
            let contentInsets = collectionView.enclosingScrollView?.contentInsets ?? .init()
            // During a shrink, NSClipView has its new width before the collection
            // applies its new bounds. Fit both, so the interim delegate query is safe.
            let viewport = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
            let usable = min(collectionView.bounds.width, viewport) - insets.left - insets.right - contentInsets.left - contentInsets.right
            return NSSize(width: max(1, usable.rounded(.down)), height: 92)
        }
        return LibraryCardItem.layout(forWidth: Double(collectionView.bounds.width)).itemSize
    }


}

/// A thumbnail card: 16:9 image with duration / resolution / star badges, the
/// name, and up to two tag chips. Pink border on hover and selection.
final class LibraryCardItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("LibraryCard")
    static let size = NSSize(width: 228, height: 196)
    static let minWidth = 220.0
    static let spacing = 16.0
    static let sideInset = 22.0
    /// Height below the 16:9 thumbnail (name + tag row).
    static let infoHeight = 68.0

    /// Column count and card size that fill a row of `width` points edge to edge.
    static func layout(forWidth width: Double) -> (columns: Int, itemSize: NSSize) {
        let usable = max(width - 2 * sideInset, minWidth)
        let columns = max(1, Int((usable + spacing) / (minWidth + spacing)))
        let w = ((usable - Double(columns - 1) * spacing) / Double(columns)).rounded(.down)
        return (columns, NSSize(width: w, height: (w * 9 / 16 + infoHeight).rounded()))
    }

    var onDoubleClick: (() -> Void)?

    private let thumb = AspectFillImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let durationBadge = Theme.chip("", color: .white, background: NSColor.black.withAlphaComponent(0.72),
                                           font: Theme.digits(11, .heavy))
    private let resolutionBadge = Theme.chip("", color: Theme.accent2, background: NSColor.black.withAlphaComponent(0.72),
                                             font: .systemFont(ofSize: 10, weight: .heavy))
    private let starBadge = Theme.chip("", color: Theme.star, background: NSColor.black.withAlphaComponent(0.72),
                                       font: Theme.digits(11, .heavy))
    private let watchedBadge = Theme.chip(L("✓ 已看完"), color: Theme.accent2, background: NSColor.black.withAlphaComponent(0.72),
                                          font: .systemFont(ofSize: 10, weight: .heavy))
    private let progress = WatchProgressStripe()
    private let tagRow = NSStackView()
    private var hovering = false { didSet { updateBorder() } }

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: Self.size))
        v.wantsLayer = true
        v.layer?.cornerRadius = Theme.radiusCard
        v.layer?.backgroundColor = Theme.bg1.cgColor
        v.layer?.masksToBounds = true


        nameLabel.font = .systemFont(ofSize: 13, weight: .bold)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        tagRow.spacing = 6

        for s in [thumb, nameLabel, tagRow] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        for b in [durationBadge, resolutionBadge, starBadge, watchedBadge, progress] as [NSView] {
            b.translatesAutoresizingMaskIntoConstraints = false; thumb.addSubview(b)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: v.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 9.0 / 16.0),
            durationBadge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -7),
            durationBadge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -7),
            resolutionBadge.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 7),
            resolutionBadge.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 7),
            starBadge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -7),
            starBadge.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 7),
            watchedBadge.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 7),
            watchedBadge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -7),
            progress.leadingAnchor.constraint(equalTo: thumb.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: thumb.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: thumb.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 4),
            nameLabel.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            tagRow.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            tagRow.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            tagRow.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),
        ])
        v.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                         owner: self, userInfo: nil))
        view = v
    }

    func configure(_ item: LibraryItem, thumbnail: URL) {
        nameLabel.stringValue = item.name
        nameLabel.toolTip = item.record.path
        durationBadge.stringValue = item.record.duration > 0 ? TimeFormatting.string(item.record.duration) : ""
        durationBadge.isHidden = item.record.duration <= 0
        let res = LibraryGrouping.resolutionBucket(width: item.record.width, height: item.record.height)
        resolutionBadge.stringValue = res == .uhd ? "4K" : res == .fullHD ? "HD" : ""
        resolutionBadge.isHidden = resolutionBadge.stringValue.isEmpty
        starBadge.stringValue = "★ \(item.starCount)"
        starBadge.isHidden = item.starCount == 0
        // Watched: a tick; started: how far, as a stripe along the bottom of the cover.
        let watched = item.watch?.isWatched == true
        watchedBadge.isHidden = !watched
        progress.fraction = watched ? 0 : item.watch?.fraction ?? 0
        progress.isHidden = progress.fraction <= 0

        tagRow.views.forEach { $0.removeFromSuperview() }
        var chips: [NSTextField] = item.tags.prefix(2).map { Theme.chip(L($0)) }      // tags are stored in Chinese
        if item.record.status == .cloudOnly { chips = [Theme.chip(L("iCloud 未下载"), color: Theme.accent2)] }
        if chips.isEmpty, res != .unknown { chips = [Theme.chip(res.title)] }
        chips.forEach { tagRow.addArrangedSubview($0) }

        thumb.image = NSImage(contentsOf: thumbnail)
    }

    /// Texts on the card, for tests.
    var textsForTesting: [String] {
        [nameLabel.stringValue, durationBadge.isHidden ? "" : durationBadge.stringValue,
         resolutionBadge.isHidden ? "" : resolutionBadge.stringValue, starBadge.isHidden ? "" : starBadge.stringValue,
         watchedBadge.isHidden ? "" : watchedBadge.stringValue,
         progress.isHidden ? "" : String(format: "%.0f%%", progress.fraction * 100)]
            + tagRow.views.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func updateBorder() {
        let on = isSelected || hovering
        view.layer?.borderWidth = on ? 2 : 0
        view.layer?.borderColor = Theme.accent.cgColor
    }

    override var isSelected: Bool { didSet { updateBorder() } }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

/// Draws its image scaled to fill (cropping the overflow), like CSS object-fit: cover.
/// Plain drawing (not layer contents) so it also shows in snapshots.
final class AspectFillImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var placeholderSymbol = "film"

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg2.setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else {
            if let icon = NSImage(systemSymbolName: placeholderSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 26, weight: .bold)) {
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r); Theme.textTertiary.set(); r.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: bounds.midX - icon.size.width / 2, y: bounds.midY - icon.size.height / 2,
                                       width: icon.size.width, height: icon.size.height))
            }
            return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}

final class LibrarySectionHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("LibraryHeader")
    private let label = NSTextField(labelWithString: "")
    private let count = Theme.chip("", color: Theme.accent, background: Theme.accent.withAlphaComponent(0.16),
                                   font: Theme.digits(11, .heavy))
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Theme.display(18, .heavy)
        label.textColor = Theme.textPrimary
        let row = NSStackView(views: [label, count])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
                                     row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func set(title: String, count n: Int) {
        label.stringValue = title
        count.stringValue = "\(n)"
    }
}

/// Sidebar selection: a soft pink pill instead of the system highlight.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 8, dy: 1)
        Theme.accent.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2).fill()
        Theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + 7, width: 3, height: r.height - 14), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
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
