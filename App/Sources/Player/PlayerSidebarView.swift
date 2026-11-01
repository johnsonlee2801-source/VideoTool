import AppKit

/// One retained sidebar for library, recent playback and the current video's stars.
/// The player owns its width; this view owns presentation, focus and observation.
final class PlayerSidebarView: NSView {
    private(set) var state: PlayerSidebarState
    private let preferences: PlayerSidebarPreferences?
    private let libraryProvider: () -> LibraryController?
    private let history: WatchHistoryStore
    private let bookmarks: BookmarkListView
    private let onOpen: (URL) -> Void
    private(set) var libraryBrowser: LibraryBrowserViewController?
    private var libraryModel: LibraryController?
    private let inner = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 640))
    private let body = NSView()
    private let tabs = NSStackView()
    private var tabButtons: [NSButton] = []
    private let message = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: L("重试"), target: nil, action: nil)
    private var historyObserver: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?
    private var stopped = false
    private var nextVideoPath: String?
    private var videoEnded = false
    var onLayoutChange: (() -> Void)?
    var currentPath: String? {
        didSet { libraryBrowser?.currentPath = currentPath; recent.currentPath = currentPath }
    }
    var errorMessage: String { message.stringValue }
    var tabTitles: [String] { tabButtons.map(\.title) }
    private(set) lazy var recent = RecentPlaybackViewController(history: history,
        index: { [weak self] in self?.libraryModel?.items ?? [] },
        thumbnail: { [weak self] in self?.libraryModel?.thumbnailURL(for: $0) },
        onOpen: { [weak self] in self?.openMedia($0) })

    init(bookmarks: BookmarkListView, preferences: PlayerSidebarPreferences?, history: WatchHistoryStore,
         libraryProvider: @escaping () -> LibraryController?, onOpen: @escaping (URL) -> Void) {
        self.bookmarks = bookmarks
        self.preferences = preferences ?? (AppData.isTestRun ? nil : PlayerSidebarPreferences())
        self.history = history; self.libraryProvider = libraryProvider; self.onOpen = onOpen
        state = self.preferences?.load() ?? PlayerSidebarState()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor
        layer?.masksToBounds = true
        build()
        historyObserver = NotificationCenter.default.addObserver(forName: WatchHistoryStore.didChange,
            object: history.notificationObject, queue: .main) { [weak self] _ in self?.scheduleHistoryRefresh() }
        present()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit {
        refreshWork?.cancel()
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }
    private func build() {
        addSubview(inner)
        tabs.distribution = .fillEqually
        tabs.spacing = 4
        for (i, title) in [L("视频库"), L("最近播放"), L("星标")].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(tabChanged(_:)))
            button.tag = i
            button.setButtonType(.toggle)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = Theme.radiusSmall
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tabButtons.append(button)
            tabs.addArrangedSubview(button)
        }
        tabs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(image: NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: L("收起侧栏"))!,
                             target: self, action: #selector(closePressed(_:)))
        close.isBordered = false; close.contentTintColor = Theme.textSecondary
        close.toolTip = L("收起侧栏")
        close.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [tabs, close])
        header.spacing = 8
        message.textColor = Theme.textSecondary
        message.font = .systemFont(ofSize: 12, weight: .medium)
        retry.target = self; retry.action = #selector(retryLibrary(_:))
        let notice = NSStackView(views: [message, retry])
        notice.orientation = .vertical
        notice.spacing = 6
        for child in [header, notice, body] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false; inner.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: inner.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -12),
            tabs.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -32),
            notice.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            notice.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 14),
            notice.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -14),
            body.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 5),
            body.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
        ])
        addContent(bookmarks)
        addContent(recent.view)
        let divider = SidebarDragDivider()
        divider.width = { [weak self] in self?.bounds.width ?? 380 }
        divider.onResize = { [weak self] in self?.resize(to: $0) }
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 5),
        ])
    }
    private func addContent(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: body.leadingAnchor), child.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            child.topAnchor.constraint(equalTo: body.topAnchor), child.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }
    override func layout() {
        super.layout()
        // Keep the hidden inner layout valid at zero outer width, without forcing
        // a minimum width constraint onto the collapsed player sidebar.
        inner.frame = NSRect(x: 0, y: 0, width: max(280, bounds.width), height: bounds.height > 0 ? bounds.height : 640)
    }
    func show(_ tab: PlayerSidebarTab) {
        guard !stopped else { return }
        window?.makeFirstResponder(nil)
        message.stringValue = ""
        state.show(tab)
        if tab == .library { libraryBrowser?.refreshFromStore() }
        changed()
    }
    func close() { window?.makeFirstResponder(nil); state.close(); changed() }
    func toggleStars() { window?.makeFirstResponder(nil); state.toggleStars(); changed() }
    func resize(to width: CGFloat) {
        state.preferredWidth = width
        state.preferredWidth = state.boundedWidth
        preferences?.save(state)
        needsLayout = true
        onLayoutChange?()
    }
    private func changed() { preferences?.save(state); present(); onLayoutChange?() }
    private func present() {
        isHidden = !state.isExpanded
        for button in tabButtons {
            let selected = button.tag == state.tab.rawValue
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = (selected ? Theme.accent.withAlphaComponent(0.18) : NSColor.clear).cgColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: selected ? Theme.accent : Theme.textSecondary])
        }
        if state.isExpanded && state.tab != .stars { ensureLibrary(showError: state.tab == .library) }
        bookmarks.isHidden = !state.isExpanded || state.tab != .stars
        libraryBrowser?.view.isHidden = state.tab != .library
        recent.view.isHidden = state.tab != .recent
        retry.isHidden = state.tab != .library || libraryBrowser != nil || !state.isExpanded
        message.isHidden = message.stringValue.isEmpty
        if state.isExpanded && state.tab == .recent { recent.refresh() }
        needsLayout = true
    }
    private func ensureLibrary(showError: Bool) {
        if libraryBrowser != nil { return }
        guard let model = libraryProvider() else {
            if showError { message.stringValue = L("暂时无法打开视频库") }
            return
        }
        libraryModel = model
        let browser = LibraryBrowserViewController(controller: model) { [weak self] in self?.openMedia($0) }
        libraryBrowser = browser
        browser.currentPath = currentPath
        browser.folderBrowser?.setPlaybackNavigation(next: nextVideoPath, ended: videoEnded)
        browser.onItemsChange = { [weak self] in
            guard let self, self.state.isExpanded, self.state.tab == .recent else { return }
            self.recent.refresh()
        }
        addContent(browser.view)
        message.stringValue = ""
    }
    private func scheduleHistoryRefresh() {
        guard !stopped, state.isExpanded, state.tab != .stars else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.libraryBrowser?.refreshFromStore()
            if self.state.tab == .recent { self.recent.refresh() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func refreshMetadata() { scheduleHistoryRefresh() }
    func updatePlaybackNavigation(next: String?, ended: Bool) {
        guard next != nextVideoPath || ended != videoEnded else { return }
        nextVideoPath = next; videoEnded = ended
        libraryBrowser?.folderBrowser?.setPlaybackNavigation(next: next, ended: ended)
    }
    func openMedia(_ url: URL) {
        guard !stopped else { return }
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            message.stringValue = L("无法打开视频：文件不存在或暂时无法访问")
            message.isHidden = false
            return
        }
        message.stringValue = ""; message.isHidden = true
        onOpen(url)
    }
    func containsFocus(_ responder: NSResponder?) -> Bool {
        guard !isHidden, let view = responder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }
    func shutdown() {
        guard !stopped else { return }
        stopped = true
        refreshWork?.cancel(); refreshWork = nil
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
        historyObserver = nil
        libraryBrowser?.shutdown()
        libraryModel?.cancelScan()
    }
    @objc private func tabChanged(_ sender: NSButton) { if let tab = PlayerSidebarTab(rawValue: sender.tag) { show(tab) } }
    @objc private func closePressed(_ sender: Any?) { close() }
    @objc private func retryLibrary(_ sender: Any?) { show(.library) }
}

private final class SidebarDragDivider: NSView {
    var onResize: ((CGFloat) -> Void)?
    var width: (() -> CGFloat)?
    private var downX: CGFloat = 0
    private var downWidth: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = Theme.stroke.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { downX = event.locationInWindow.x; downWidth = width?() ?? 380 }
    override func mouseDragged(with event: NSEvent) { onResize?(downWidth + downX - event.locationInWindow.x) }
}
