import AppKit

/// The interface language the user picked in VideoTool (nil: follow the system).
/// Stored as the app's own AppleLanguages, which macOS applies at launch to
/// everything: our text, menus and system panels alike.
enum LanguageSetting {
    static let key = "videotool.language"
    /// Named in their own script, so anyone can find theirs whatever is showing now.
    static let languages: [(code: String, name: String)] = [("en", "English"), ("zh-Hans", "简体中文"), ("ja", "日本語")]

    static func current(_ defaults: UserDefaults = AppData.defaults) -> String? {
        defaults.string(forKey: key)
    }

    static func set(_ code: String?, in defaults: UserDefaults = AppData.defaults) {
        if let code {
            defaults.set(code, forKey: key)
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}

/// VideoTool › 语言 · Language.
final class LanguageMenuController: NSObject, NSMenuItemValidation {
    let menu = NSMenu(title: L("语言 · Language"))
    private let defaults: UserDefaults
    private let confirmRestart: (String?) -> Bool
    private let relaunch: () -> Void

    init(defaults: UserDefaults = AppData.defaults,
         confirmRestart: @escaping (String?) -> Bool = LanguageMenuController.askToRestart,
         relaunch: @escaping () -> Void = LanguageMenuController.relaunchApp) {
        self.defaults = defaults
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
        guard code != LanguageSetting.current(defaults) else { return }
        LanguageSetting.set(code, in: defaults)
        if confirmRestart(code) { relaunch() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = (item.representedObject as? String) == LanguageSetting.current(defaults) ? .on : .off
        return true
    }

    /// The prompt's text in the newly chosen language (the current one for Follow System).
    static func restartPrompt(for code: String?) -> (message: String, info: String, now: String, later: String) {
        let bundle = code.flatMap(Localization.bundle(for:)) ?? Localization.bundle
        return (L("重新打开 VideoTool 后切换语言", in: bundle), L("正在播放的位置会保存。", in: bundle),
                L("现在重新打开", in: bundle), L("稍后", in: bundle))
    }

    static func askToRestart(_ code: String?) -> Bool {
        let text = restartPrompt(for: code)
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.info
        alert.addButton(withTitle: text.now)
        alert.addButton(withTitle: text.later)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quits, and opens VideoTool again once this process has gone.
    static func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
