import AppKit

/// The interface language the user picked in VideoTool (nil: follow the system).
/// Stored as the app's own AppleLanguages, which macOS applies at launch to
/// everything: our text, menus and system panels alike.
enum LanguageSetting {
    /// Named in their own script, so anyone can find theirs whatever is showing now.
    static let languages: [(code: String, name: String)] = [("en", "English"), ("zh-Hans", "简体中文"), ("ja", "日本語")]

    /// The app's own AppleLanguages, whoever set it: this menu, or macOS System Settings ›
    /// Language & Region › Applications. Region variants map to ours ("en-GB" → "en").
    /// Read from the stored domain only: the global and command-line values do not count.
    static func current(_ defaults: UserDefaults = AppData.defaults, domain: String = AppData.defaultsDomain) -> String? {
        guard let first = (defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String])?.first else { return nil }
        return languages.map(\.code).first { first == $0 || first.hasPrefix($0 + "-") } ?? first
    }

    static func set(_ code: String?, in defaults: UserDefaults = AppData.defaults) {
        if let code { defaults.set([code], forKey: "AppleLanguages") } else { defaults.removeObject(forKey: "AppleLanguages") }
    }
}

/// VideoTool › 语言 · Language.
final class LanguageMenuController: NSObject, NSMenuItemValidation {
    let menu = NSMenu(title: L("语言 · Language"))
    private let defaults: UserDefaults
    private let domain: String
    private let confirmRestart: (String?) -> Bool
    private let relaunch: () -> Void

    init(defaults: UserDefaults = AppData.defaults, domain: String = AppData.defaultsDomain,
         confirmRestart: @escaping (String?) -> Bool = LanguageMenuController.askToRestart,
         relaunch: @escaping () -> Void = LanguageMenuController.relaunchApp) {
        self.defaults = defaults
        self.domain = domain
        self.confirmRestart = confirmRestart
        self.relaunch = relaunch
        super.init()
        let system = menu.addItem(withTitle: L("跟随系统"), action: #selector(chooseLanguage(_:)), keyEquivalent: "")
        system.target = self
        menu.addItem(.separator())
        for l in LanguageSetting.languages {
            let item = menu.addItem(withTitle: l.name, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = l.code
        }
    }

    @objc func chooseLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String
        guard code != LanguageSetting.current(defaults, domain: domain) else { return }
        LanguageSetting.set(code, in: defaults)
        if confirmRestart(code) { relaunch() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = (item.representedObject as? String) == LanguageSetting.current(defaults, domain: domain) ? .on : .off
        return true
    }

    /// The prompt's text in the newly chosen language (the current one for Follow System).
    static func restartPrompt(for code: String?) -> (message: String, info: String, now: String, later: String) {
        let bundle = code.flatMap(Localization.bundle(for:)) ?? Localization.bundle
        return (L("重新打开 VideoTool 后切换语言", in: bundle), L("正在播放的位置会保存。", in: bundle),
                L("现在重新打开", in: bundle), L("稍后", in: bundle))
    }

    static func makeRestartAlert(for code: String?) -> NSAlert {
        let text = restartPrompt(for: code)
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.info
        alert.addButton(withTitle: text.now)
        alert.addButton(withTitle: text.later)
        return alert
    }

    static func askToRestart(_ code: String?) -> Bool {
        makeRestartAlert(for: code).runModal() == .alertFirstButtonReturn
    }

    /// /bin/sh arguments that wait for `pid` to exit, then open the app. The path
    /// goes in as $0, so no character in it can change the script.
    static func relaunchArguments(pid: Int32, appPath: String) -> [String] {
        ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", appPath]
    }

    /// Quits, and opens VideoTool again once this process has gone.
    static func relaunchApp() {
        relaunch(launch: {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = relaunchArguments(pid: getpid(), appPath: Bundle.main.bundlePath)
            try task.run()
        }, terminate: { NSApp.terminate(nil) }, report: { message in
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        })
    }

    /// Quits only once the reopening helper is running: if it cannot start, VideoTool
    /// stays open and says so (quitting would leave the user with no app; audit 2026-10-20).
    static func relaunch(launch: () throws -> Void, terminate: () -> Void, report: (String) -> Void) {
        do { try launch() } catch {
            report(L("无法自动重新打开 VideoTool，请手动退出后再打开。"))
            return
        }
        terminate()
    }
}
