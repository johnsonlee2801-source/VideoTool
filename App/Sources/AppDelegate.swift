import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private(set) var playerWindow: PlayerWindowController?
    private var libraryWindow: LibraryWindowController?
    /// One library model for the window and for folders added from the player.
    private(set) lazy var libraryController: LibraryController? = {
        guard let store = try? LibraryStore() else { return nil }
        let path = SQLiteDatabase.defaultPath
        return LibraryController(
            store: store, stars: try? BookmarkStore(),
            // Each scan uses its own connection; if it cannot be opened, the scan reports it
            // instead of sharing the main-thread connection (transactions would collide).
            makeIndexer: { (try? LibraryStore(path: path)).map { LibraryIndexer(store: $0) } })
    }()
    private let offerPreferences = LibraryOfferPreferences()
    private lazy var libraryOffer = LibraryOfferCoordinator(
        preferences: offerPreferences,
        roots: { [weak self] in self?.libraryController?.rootEntries ?? [] },
        show: { [weak self] proposal in self?.playerWindow?.libraryOffer.offer(proposal) },
        add: { [weak self] proposal in self?.libraryController?.addRoot(proposal.path, recursive: proposal.wholeFolder) },
        refresh: { [weak self] root in self?.libraryController?.rescan(root) })
    private var launchQueue = LaunchOpenQueue()
    private weak var audioOutputMenu: NSMenu?

    // MARK: lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)   // one dark look everywhere (Theme)
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `VideoTool --register-defaults`: make VideoTool the default player for every
        // media type it handles, print the result, and quit (used by scripts/install.sh).
        if CommandLine.arguments.contains("--register-defaults") {
            DefaultAppRegistrar.makeDefault { summary in
                print(summary.message)
                NSApp.terminate(nil)
            }
            return
        }
        let cliFiles = CommandLine.arguments.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        ensureWindow()
        if let first = launchQueue.finishLaunching(commandLine: cliFiles) { open(first) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Before launch finishes (double-click on a file) the queue holds it.
        guard let first = launchQueue.receive(urls) else { return }
        ensureWindow()
        open(first)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        playerWindow?.shutdown()
    }

    // MARK: helpers

    @discardableResult
    private func ensureWindow() -> PlayerWindowController {
        if let w = playerWindow { return w }
        let w = PlayerWindowController()
        w.onClose = { [weak self, weak w] in
            if self?.playerWindow === w { self?.playerWindow = nil }   // a later open builds a fresh window
        }
        playerWindow = w
        w.onFileOpened = { [weak self] url in
            if url.isFileURL { self?.libraryOffer.fileOpened(url.path) }
        }
        w.libraryOffer.onAdd = { [weak self] in self?.libraryOffer.accept($0) }
        w.libraryOffer.onDecline = { [weak self] in self?.libraryOffer.decline($0) }
        w.libraryOffer.onNeverAsk = { [weak self] in self?.libraryOffer.neverAskAgain() }
        w.libraryOffer.onOpenLibrary = { [weak self] in self?.showLibrary(nil) }
        w.showWindow(nil)
        return w
    }

    private func open(_ url: URL) {
        ensureWindow().open(url)
    }

    // MARK: menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("关于 VideoTool"), action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏 VideoTool"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出 VideoTool"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: L("文件"))
        fileMenu.addItem(withTitle: L("打开…"), action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("设为默认视频播放器…"), action: #selector(makeDefaultPlayer(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: L("打开视频时询问加入视频库"), action: #selector(toggleLibraryOffer(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let playItem = NSMenuItem(); main.addItem(playItem)
        let playMenu = NSMenu(title: L("播放"))
        playMenu.addItem(withTitle: L("播放 / 暂停"), action: #selector(PlayerWindowController.togglePause(_:)), keyEquivalent: " ")
        playMenu.addItem(withTitle: L("快退 5 秒"), action: #selector(PlayerWindowController.seekBack(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("快进 5 秒"), action: #selector(PlayerWindowController.seekForward(_:)), keyEquivalent: "")
        playMenu.addItem(.separator())
        playMenu.addItem(withTitle: L("加速 0.1×"), action: #selector(PlayerWindowController.speedUp(_:)), keyEquivalent: "]")
        playMenu.addItem(withTitle: L("减速 0.1×"), action: #selector(PlayerWindowController.speedDown(_:)), keyEquivalent: "[")
        playMenu.addItem(withTitle: L("恢复 1.0×"), action: #selector(PlayerWindowController.resetSpeed(_:)), keyEquivalent: "\u{8}")
        let speedItem = playMenu.addItem(withTitle: L("播放速度"), action: nil, keyEquivalent: "")
        speedItem.submenu = PlaybackSpeed.menu(current: 1.0, target: nil,
                                               action: #selector(PlayerWindowController.chooseSpeedPreset(_:)))
        playMenu.addItem(.separator())
        // B and ⌥←/⌥→ are handled by the player's key monitor; shown here for discoverability.
        playMenu.addItem(withTitle: L("打星标 / 撤销   B"), action: #selector(PlayerWindowController.toggleBookmark(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("上一个星标   ⌥←"), action: #selector(PlayerWindowController.previousBookmark(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("下一个星标   ⌥→"), action: #selector(PlayerWindowController.nextBookmark(_:)), keyEquivalent: "")
        let list = playMenu.addItem(withTitle: L("星标列表"), action: #selector(PlayerWindowController.toggleBookmarkList(_:)), keyEquivalent: "b")
        list.keyEquivalentModifierMask = [.command, .shift]
        playMenu.addItem(.separator())
        playMenu.addItem(withTitle: L("切换字幕轨"), action: #selector(PlayerWindowController.cycleSubtitle(_:)), keyEquivalent: "s")
        playMenu.addItem(withTitle: L("AI 字幕…"), action: #selector(PlayerWindowController.generateAISubtitles(_:)), keyEquivalent: "t")
        playMenu.addItem(withTitle: L("AI 字幕背景条"), action: #selector(PlayerWindowController.toggleSubtitleBand(_:)), keyEquivalent: "")
        let sizeItem = playMenu.addItem(withTitle: L("AI 字幕大小"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: L("AI 字幕大小"))
        for (title, scale) in [(L("小"), 0.8), (L("中"), 1.0), (L("大"), 1.25)] {
            let item = sizeMenu.addItem(withTitle: title, action: #selector(PlayerWindowController.chooseSubtitleSize(_:)), keyEquivalent: "")
            item.representedObject = scale
        }
        sizeItem.submenu = sizeMenu
        playMenu.addItem(withTitle: L("导出 AI 字幕…"), action: #selector(PlayerWindowController.exportAISubtitles(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("切换音轨"), action: #selector(PlayerWindowController.cycleAudio(_:)), keyEquivalent: "a")
        playMenu.addItem(withTitle: L("字幕提前 0.1 秒   Z"), action: #selector(PlayerWindowController.subtitleEarlier(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("字幕延后 0.1 秒   X"), action: #selector(PlayerWindowController.subtitleLater(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("静音"), action: #selector(PlayerWindowController.toggleMute(_:)), keyEquivalent: "m")
        playMenu.addItem(withTitle: L("夜间模式（对白更清楚）"), action: #selector(PlayerWindowController.toggleNightMode(_:)), keyEquivalent: "")
        let skipItem = playMenu.addItem(withTitle: L("片头片尾"), action: nil, keyEquivalent: "")
        let skipMenu = NSMenu(title: L("片头片尾"))
        skipMenu.addItem(withTitle: L("片头到这里结束（本系列自动跳过）"), action: #selector(PlayerWindowController.markIntroEnd(_:)), keyEquivalent: "")
        skipMenu.addItem(withTitle: L("片尾从这里开始（本系列自动跳过）"), action: #selector(PlayerWindowController.markOutroStart(_:)), keyEquivalent: "")
        skipMenu.addItem(.separator())
        skipMenu.addItem(withTitle: L("清除本系列的片头片尾"), action: #selector(PlayerWindowController.clearSkips(_:)), keyEquivalent: "")
        skipItem.submenu = skipMenu
        let outputItem = playMenu.addItem(withTitle: L("声音输出"), action: nil, keyEquivalent: "")
        let outputMenu = NSMenu(title: L("声音输出"))
        outputMenu.delegate = self               // filled when opened: devices come and go (AirPlay, headphones)
        outputItem.submenu = outputMenu
        audioOutputMenu = outputMenu
        playItem.submenu = playMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: L("视图"))
        let fs = viewMenu.addItem(withTitle: L("全屏"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(withTitle: L("视频库"), action: #selector(showLibrary(_:)), keyEquivalent: "l")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let helpMenu = NSMenu(title: L("帮助"))
        helpMenu.addItem(withTitle: L("发送反馈…"), action: #selector(sendFeedback(_:)), keyEquivalent: "")
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaTypes.utTypes
        panel.message = L("选择要播放的视频或音频")
        if panel.runModal() == .OK, let url = panel.url {
            ensureWindow()
            open(url)
        }
    }

    /// Standard About panel, with the third-party licences as its credits.
    @objc func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            options[.credits] = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.labelColor])
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showLibrary(_ sender: Any?) {
        if libraryWindow == nil {
            guard let controller = libraryController else { return }
            libraryWindow = LibraryWindowController(controller: controller) { [weak self] url in
                self?.ensureWindow()
                self?.open(url)
            }
        }
        libraryWindow?.showWindow(nil)
        libraryWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// Re-enables the offer after "不再询问" (and lets the user turn it off from the menu).
    @objc private func toggleLibraryOffer(_ sender: NSMenuItem) {
        offerPreferences.neverAsk.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleLibraryOffer(_:)) { item.state = offerPreferences.neverAsk ? .off : .on }
        return true
    }

    @objc private func sendFeedback(_ sender: Any?) { Feedback.open() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === audioOutputMenu else { return }
        menu.removeAllItems()
        let items = playerWindow?.audioOutputItems() ?? []
        if items.isEmpty { menu.addItem(withTitle: L("（播放器未就绪）"), action: nil, keyEquivalent: "") }
        items.forEach(menu.addItem)
    }

    @objc private func makeDefaultPlayer(_ sender: Any?) {
        DefaultAppRegistrar.makeDefault { summary in
            let alert = NSAlert()
            alert.messageText = L("设为默认播放器")
            alert.informativeText = summary.message
            alert.runModal()
        }
    }
}
