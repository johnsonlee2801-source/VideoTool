import AppKit

/// The second down opens the hit-tested row exactly once; it does not depend on
/// NSTableView's private mouse-tracking state (also reachable by event tests).
private final class FolderVideoTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 2, row >= 0, !event.modifierFlags.contains(.control) {
            selectRowIndexes([row], byExtendingSelection: false)
            if let doubleAction { NSApp.sendAction(doubleAction, to: target, from: self) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// Folder-first content. Index refreshes are supplied by its parent so the
/// shared LibraryController retains a single owner for its callbacks.
final class FolderBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case folder(FolderBrowserNode), video(FolderBrowserVideo)
        var path: String { switch self { case .folder(let f): return f.path; case .video(let v): return v.path } }
    }
    private struct Position {
        var search: String; var tag: String?; var watch: FolderWatchFilter
        var selected: String?; var origin: NSPoint
    }
    private let controller: LibraryController
    private let onOpen: (URL) -> Void
    private let defaults: UserDefaults
    private let history = WatchHistoryStore()
    private let loader: FolderDirectoryLoader
    private var stopped = false
    private var temporaryRoot: String?
    private var temporary: FolderDirectory?
    private var positions: [String: Position] = [:]
    private var pendingPosition: Position?
    private var pendingLocate: String?
    private var rows: [Row] = []
    private var pathOptions: [String?] = []
    private var tag: String?
    private var watch: FolderWatchFilter = .all
    private var isLoading = false
    private var readError: String?
    private var operationMessage: String?
    private var nextVideoPath: String?
    private var videoEnded = false
    private(set) var directory: String?
    private(set) var visibleFolders: [FolderBrowserNode] = []
    private(set) var visibleVideos: [FolderBrowserVideo] = []
    let table: NSTableView = FolderVideoTable()
    let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let pathPicker = NSPopUpButton()
    private let filterButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let locateButton = NSButton()
    var onShowAdvanced: (() -> Void)?
    var currentPath: String? { didSet { if currentPath != oldValue { refresh() } } }

    init(controller: LibraryController, defaults: UserDefaults = AppData.defaults,
         loader: FolderDirectoryLoader = FolderDirectoryLoader(), onOpen: @escaping (URL) -> Void) {
        self.controller = controller; self.defaults = defaults; self.loader = loader; self.onOpen = onOpen
        let stored = defaults.string(forKey: "videotool.library.directory")
        directory = stored.flatMap { path in controller.rootEntries.contains { $0.covers(path) } ? path : nil }
        super.init(nibName: nil, bundle: nil)
        view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = Theme.bg1.cgColor
        build(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
        button.isBordered = false; button.contentTintColor = Theme.textSecondary; button.toolTip = title
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }
    private func build() {
        let up = button("chevron.left", L("上一级文件夹"), #selector(goUp(_:)))
        pathPicker.target = self; pathPicker.action = #selector(pathChanged(_:))
        pathPicker.font = .systemFont(ofSize: 12, weight: .semibold)
        pathPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locateButton.image = NSImage(systemSymbolName: "scope", accessibilityDescription: L("定位当前视频所在文件夹"))
        locateButton.target = self; locateButton.action = #selector(locateCurrent(_:))
        locateButton.isBordered = false; locateButton.contentTintColor = Theme.accent2
        locateButton.toolTip = L("定位当前视频所在文件夹")
        locateButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let pathBar = NSStackView(views: [up, pathPicker, locateButton]); pathBar.spacing = 5
        searchField.placeholderString = L("搜索当前文件夹")
        searchField.delegate = self
        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: L("筛选"))
        filterButton.target = self; filterButton.action = #selector(showFilters(_:))
        filterButton.isBordered = false; filterButton.toolTip = L("筛选")
        filterButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let searchBar = NSStackView(views: [searchField, filterButton]); searchBar.spacing = 5
        let advanced = NSButton(title: L("更多整理"), target: self, action: #selector(showAdvanced(_:)))
        advanced.isBordered = false; advanced.font = .systemFont(ofSize: 11, weight: .medium)
        advanced.contentTintColor = Theme.textSecondary
        let tools = NSStackView(views: [button("folder.badge.plus", L("添加文件夹…"), #selector(addFolder(_:))),
            button("arrow.clockwise", L("重新扫描"), #selector(rescan(_:))),
            button("folder", L("在 Finder 中显示"), #selector(reveal(_:))), NSView(), advanced])
        tools.spacing = 6
        let header = NSStackView(views: [pathBar, searchBar, tools]); header.orientation = .vertical
        header.alignment = .leading; header.spacing = 5
        for bar in [pathBar, searchBar, tools] { bar.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        table.addTableColumn(NSTableColumn(identifier: .init("folder-video")))
        table.headerView = nil; table.backgroundColor = Theme.bg1
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .none
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelection(_:))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        status.font = .systemFont(ofSize: 10, weight: .medium); status.textColor = Theme.textSecondary
        status.lineBreakMode = .byTruncatingTail
        empty.font = .systemFont(ofSize: 12, weight: .medium); empty.textColor = Theme.textSecondary; empty.alignment = .center
        for child in [header, scroll, status, empty] as [NSView] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -5),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private var indexed: Bool { directory.map { path in controller.rootEntries.contains { $0.covers(path) } } ?? true }
    private var positionKey: String { directory ?? "" }
    private func savePosition() {
        positions[positionKey] = Position(search: searchField.stringValue, tag: tag, watch: watch,
            selected: rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].path : nil, origin: scroll.contentView.bounds.origin)
    }
    func enter(_ path: String?) {
        guard !stopped else { return }
        savePosition(); loader.cancel(); temporary = nil; readError = nil; operationMessage = nil; isLoading = false
        directory = path.map(LibraryStore.normalized)
        if let path = directory, indexed { defaults.set(path, forKey: "videotool.library.directory") }
        else { defaults.removeObject(forKey: "videotool.library.directory") }
        let saved = positions[positionKey]
        pendingPosition = saved; pendingLocate = nil
        searchField.stringValue = saved?.search ?? ""; tag = saved?.tag; watch = saved?.watch ?? .all
        if let path = directory, !indexed {
            if temporaryRoot == nil || !FolderBrowserModel.contains(path, in: temporaryRoot!) { temporaryRoot = path }
            isLoading = true
            loader.load(path) { [weak self] result in
                guard let self, !self.stopped else { return }
                self.isLoading = false
                switch result { case .success(let data): self.temporary = data; case .failure(let error): self.readError = error.localizedDescription }
                self.refresh()
            }
        }
        table.deselectAll(nil); refresh()
        if let saved {
            if let path = saved.selected, let row = rows.firstIndex(where: { $0.path == path }) { table.selectRowIndexes([row], byExtendingSelection: false) }
            scroll.contentView.scroll(to: saved.origin)
        } else { scroll.contentView.scroll(to: .zero) }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc func goUp(_ sender: Any?) {
        guard let directory else { return }
        if controller.roots.contains(directory) || directory == temporaryRoot { enter(nil) }
        else { enter((directory as NSString).deletingLastPathComponent) }
    }
    @objc private func pathChanged(_ sender: Any?) {
        guard pathOptions.indices.contains(pathPicker.indexOfSelectedItem) else { return }
        enter(pathOptions[pathPicker.indexOfSelectedItem])
    }
    @objc private func locateCurrent(_ sender: Any?) {
        guard let currentPath else { return }
        enter((currentPath as NSString).deletingLastPathComponent)
        pendingLocate = currentPath
        restorePendingPosition()
    }
    private func updatePath() {
        pathOptions = [nil]
        if let directory {
            let root = controller.roots.filter { FolderBrowserModel.contains(directory, in: $0) }.max { $0.count < $1.count } ?? temporaryRoot ?? directory
            var part = root; pathOptions.append(part)
            if directory != root {
                let rest = directory.dropFirst(root == "/" ? 1 : root.count + 1)
                for component in rest.split(separator: "/") { part = (part as NSString).appendingPathComponent(String(component)); pathOptions.append(part) }
            }
        }
        pathPicker.removeAllItems()
        for path in pathOptions { pathPicker.addItem(withTitle: path.map { ($0 as NSString).lastPathComponent.isEmpty ? "/" : ($0 as NSString).lastPathComponent } ?? L("视频库文件夹")) }
        pathPicker.selectItem(at: pathOptions.count - 1); pathPicker.toolTip = directory ?? L("视频库文件夹")
        locateButton.isEnabled = currentPath != nil
    }
    func refresh() {
        guard !stopped else { return }
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].path : nil
        let origin = scroll.contentView.bounds.origin
        let snapshot: FolderBrowserSnapshot
        if !indexed, let temporary {
            let byPath = Dictionary(controller.items.map { ($0.record.path, $0) }, uniquingKeysWith: { a, _ in a })
            snapshot = FolderBrowserSnapshot(folders: temporary.folders.map { FolderBrowserNode(path: $0, videoCount: -1) },
                videos: FolderBrowserModel.filter(temporary.videos.map { FolderBrowserVideo(path: $0, item: byPath[$0]) },
                    search: searchField.stringValue, tag: tag, watch: watch, history: history.all))
        } else {
            snapshot = FolderBrowserModel.snapshot(path: directory, roots: controller.roots, items: controller.items,
                search: searchField.stringValue, tag: tag, watch: watch)
        }
        visibleFolders = snapshot.folders; visibleVideos = snapshot.videos
        rows = visibleFolders.map(Row.folder) + visibleVideos.map(Row.video)
        table.reloadData()
        if let selected, let row = rows.firstIndex(where: { $0.path == selected }) { table.selectRowIndexes([row], byExtendingSelection: false) }
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        updatePath()
        refreshStatus()
        let filtered = !searchField.stringValue.isEmpty || tag != nil || watch != .all
        filterButton.contentTintColor = filtered ? Theme.accent : Theme.textSecondary
        empty.stringValue = readError != nil ? L("文件夹暂不可用，请检查磁盘后重试。") : isLoading ? L("正在读取文件夹…")
            : controller.roots.isEmpty && directory == nil ? L("添加视频文件夹，或定位当前视频所在文件夹。\n只建立索引，不会移动文件。")
            : filtered ? L("没有符合条件的视频") : L("当前文件夹没有视频")
        empty.isHidden = !rows.isEmpty
        restorePendingPosition()
    }
    /// Watch filters may change membership; otherwise keep row order, search,
    /// selection and scroll and repaint only visible rows.
    func refreshWatchHistory(_ watched: [String: WatchEntry]) {
        guard !stopped else { return }
        if watch != .all { refresh(); return }
        for index in visibleVideos.indices {
            let path = visibleVideos[index].path
            visibleVideos[index].item?.watch = watched[path]
        }
        for index in rows.indices {
            if case .video(var video) = rows[index] {
                video.item?.watch = watched[video.path]
                rows[index] = .video(video)
            }
        }
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound, visible.length > 0 {
            let end = min(rows.count, visible.location + visible.length)
            if visible.location < end {
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<end), columnIndexes: [0])
            }
        }
    }
    func refreshStatus() {
        if let operationMessage { status.stringValue = operationMessage }
        else if let readError { status.stringValue = L("无法读取文件夹：%@", readError) }
        else if let notice = controller.notice { status.stringValue = notice }
        else if isLoading { status.stringValue = L("正在读取文件夹…") }
        else if controller.isIndexing { status.stringValue = controller.statusText }
        else if videoEnded, let directory, currentPath.map({ ($0 as NSString).deletingLastPathComponent }) == directory {
            status.stringValue = nextVideoPath.map { L("本集已结束 · 下一集：%@", ($0 as NSString).lastPathComponent) } ?? L("本文件夹已播完")
        } else {
            status.stringValue = directory == nil ? L("%@ 个视频库文件夹", String(visibleFolders.count))
                : L("本层 %@ 个视频 · %@ 个子文件夹", String(visibleVideos.count), String(visibleFolders.count))
        }
        status.toolTip = status.stringValue
    }
    private func restorePendingPosition() {
        guard !isLoading else { return }
        if let saved = pendingPosition {
            pendingPosition = nil
            if let selected = saved.selected, let row = rows.firstIndex(where: { $0.path == selected }) { table.selectRowIndexes([row], byExtendingSelection: false) }
            scroll.contentView.scroll(to: saved.origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
        if let path = pendingLocate {
            pendingLocate = nil
            if let row = rows.firstIndex(where: { $0.path == path }) { table.selectRowIndexes([row], byExtendingSelection: false); table.scrollRowToVisible(row) }
        }
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func setPlaybackNavigation(next: String?, ended: Bool) {
        guard next != nextVideoPath || ended != videoEnded else { return }
        nextVideoPath = next; videoEnded = ended; refresh()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 32 }
        if case .folder = rows[row] { return 32 }; return 62
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .folder(let folder):
            let id = NSUserInterfaceItemIdentifier("FolderBrowserDirectory")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
            cell.identifier = id
            if cell.textField == nil {
                let label = NSTextField(labelWithString: ""), icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
                label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = Theme.textPrimary; label.lineBreakMode = .byTruncatingMiddle
                icon.contentTintColor = Theme.accent2
                let stack = NSStackView(views: [icon, label]); stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack); cell.textField = label
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18)])
            }
            let name = (folder.path as NSString).lastPathComponent
            let duplicate = visibleFolders.filter { ($0.path as NSString).lastPathComponent == name }.count > 1
            cell.textField?.stringValue = (duplicate ? folder.path : name) + (folder.videoCount >= 0 ? "  ·  \(folder.videoCount)" : "")
            cell.toolTip = folder.path + (folder.videoCount >= 0 ? "\n" + L("含子文件夹，共 %@ 个视频", String(folder.videoCount)) : "")
            return cell
        case .video(let video):
            let id = NSUserInterfaceItemIdentifier("FolderBrowserVideo")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarMediaRow) ?? SidebarMediaRow(frame: .zero, compact: true)
            cell.identifier = id
            cell.configure(path: video.path, item: video.item, watch: video.watch ?? history.entry(for: video.path),
                thumbnail: video.item.map(controller.thumbnailURL), recent: false, current: video.path == currentPath)
            cell.isSelected = row == table.selectedRow
            return cell
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        for row in 0..<table.numberOfRows { (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarMediaRow)?.isSelected = row == table.selectedRow }
    }
    @objc private func openSelection(_ sender: Any?) {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .folder(let folder): enter(folder.path)
        case .video(let video):
            guard FileManager.default.fileExists(atPath: video.path) else { operationMessage = L("文件已不可用：%@", video.path); refresh(); return }
            operationMessage = nil
            refreshStatus()
            onOpen(URL(fileURLWithPath: video.path))
        }
    }
    func filterMenu() -> NSMenu {
        let menu = NSMenu()
        for value in FolderWatchFilter.allCases {
            let item = ClosureMenuItem(value.title) { [weak self] in self?.watch = value; self?.refresh() }
            item.state = watch == value ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let allTags = ClosureMenuItem(L("全部标签")) { [weak self] in self?.tag = nil; self?.refresh() }
        allTags.state = tag == nil ? .on : .off; menu.addItem(allTags)
        for value in Set(controller.items.flatMap(\.tags)).sorted() {
            let item = ClosureMenuItem(L(value)) { [weak self] in self?.tag = value; self?.refresh() }
            item.state = tag == value ? .on : .off; menu.addItem(item)
        }
        return menu
    }
    @objc private func showFilters(_ sender: Any?) {
        filterMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.height), in: filterButton)
    }
    @objc private func showAdvanced(_ sender: Any?) { onShowAdvanced?() }
    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = L("选择放视频的文件夹。VideoTool 只读取、建索引，不会移动或修改文件。")
        guard view.window != nil, panel.runModal() == .OK else { return }
        for url in panel.urls { controller.addRoot(url.path) }
    }
    @objc private func rescan(_ sender: Any?) {
        if !indexed { enter(directory) } else { controller.rescanAll() }
    }
    @objc private func reveal(_ sender: Any?) { if let directory { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory) } }
    func shutdown() { stopped = true; loader.cancel(); onShowAdvanced = nil }
}
