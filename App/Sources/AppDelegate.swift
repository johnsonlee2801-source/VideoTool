import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var playerWindow: PlayerWindowController?
    private var launchQueue = LaunchOpenQueue()

    // MARK: lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        appMenu.addItem(withTitle: "关于 VideoTool", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 VideoTool", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 VideoTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "打开…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "设为默认视频播放器…", action: #selector(makeDefaultPlayer(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let playItem = NSMenuItem(); main.addItem(playItem)
        let playMenu = NSMenu(title: "播放")
        playMenu.addItem(withTitle: "播放 / 暂停", action: #selector(PlayerWindowController.togglePause(_:)), keyEquivalent: " ")
        playMenu.addItem(withTitle: "快退 5 秒", action: #selector(PlayerWindowController.seekBack(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: "快进 5 秒", action: #selector(PlayerWindowController.seekForward(_:)), keyEquivalent: "")
        playMenu.addItem(.separator())
        playMenu.addItem(withTitle: "加速 0.1×", action: #selector(PlayerWindowController.speedUp(_:)), keyEquivalent: "]")
        playMenu.addItem(withTitle: "减速 0.1×", action: #selector(PlayerWindowController.speedDown(_:)), keyEquivalent: "[")
        playMenu.addItem(withTitle: "恢复 1.0×", action: #selector(PlayerWindowController.resetSpeed(_:)), keyEquivalent: "\u{8}")
        playMenu.addItem(.separator())
        playMenu.addItem(withTitle: "切换字幕轨", action: #selector(PlayerWindowController.cycleSubtitle(_:)), keyEquivalent: "s")
        playMenu.addItem(withTitle: "切换音轨", action: #selector(PlayerWindowController.cycleAudio(_:)), keyEquivalent: "a")
        playMenu.addItem(withTitle: "静音", action: #selector(PlayerWindowController.toggleMute(_:)), keyEquivalent: "m")
        playItem.submenu = playMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        let fs = viewMenu.addItem(withTitle: "全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaTypes.utTypes
        panel.message = "选择要播放的视频或音频"
        if panel.runModal() == .OK, let url = panel.url {
            ensureWindow()
            open(url)
        }
    }

    @objc private func makeDefaultPlayer(_ sender: Any?) {
        DefaultAppRegistrar.makeDefault { summary in
            let alert = NSAlert()
            alert.messageText = "设为默认播放器"
            alert.informativeText = summary.message
            alert.runModal()
        }
    }
}
