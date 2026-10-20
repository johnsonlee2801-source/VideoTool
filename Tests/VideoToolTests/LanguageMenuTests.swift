import AppKit
import Testing
@testable import VideoTool

// Choosing the interface language inside the app (2026-10-20): Follow System,
// English, 简体中文, 日本語. Takes effect when VideoTool reopens.

private func freshDomain() -> (defaults: UserDefaults, name: String) {
    let name = "videotool-tests-lang-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return (d, name)
}

struct LanguageSettingTests {
    @Test("LG1 a chosen language is stored for the next launch; Follow System removes it")
    func stores() {
        let (d, name) = freshDomain()
        // What is saved, not what is read back: the test runner's -AppleLanguages argument outranks it.
        func saved() -> Any? { d.persistentDomain(forName: name)?["AppleLanguages"] }
        #expect(LanguageSetting.current(d, domain: name) == nil, "follows the system by default")
        LanguageSetting.set("ja", in: d)
        #expect(LanguageSetting.current(d, domain: name) == "ja")
        #expect(saved() as? [String] == ["ja"], "what macOS reads at launch")
        LanguageSetting.set(nil, in: d)
        #expect(LanguageSetting.current(d, domain: name) == nil)
        #expect(saved() == nil)
    }

    @Test("LG8 a language chosen for VideoTool in macOS System Settings shows as the current choice")
    func systemSettingsChoice() {
        let (d, name) = freshDomain()
        for (stored, shown) in [(["ja"], "ja"), (["en-GB"], "en"), (["zh-Hans-CN"], "zh-Hans"), (["zh-Hans"], "zh-Hans")] {
            d.set(stored, forKey: "AppleLanguages")                  // what System Settings writes
            #expect(LanguageSetting.current(d, domain: name) == shown, "\(stored)")
        }
        d.set(["fr"], forKey: "AppleLanguages")
        #expect(LanguageSetting.current(d, domain: name) == "fr", "not one of ours: none of the three is ticked")
    }

    @Test("LG2 every offered language ships a full translation, and each is named in its own script")
    func offered() {
        #expect(LanguageSetting.languages.map(\.code) == ["en", "zh-Hans", "ja"])
        #expect(LanguageSetting.languages.map(\.name) == ["English", "简体中文", "日本語"])
        for l in LanguageSetting.languages { #expect(Localization.bundle(for: l.code) != nil, "\(l.code).lproj") }
    }
}

@Suite(.serialized) @MainActor struct LanguageMenuTests {
    @Test("LG3 the menu lists Follow System and the three languages, ticking the current choice")
    func menu() throws {
        let (d, name) = freshDomain()
        let c = LanguageMenuController(defaults: d, domain: name, confirmRestart: { _ in false }, relaunch: {})
        let titles = c.menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [L("跟随系统"), "English", "简体中文", "日本語"])
        func ticked() -> [String] {
            c.menu.items.filter { !$0.isSeparatorItem && { _ = c.validateMenuItem($0); return $0.state == .on }($0) }.map(\.title)
        }
        #expect(ticked() == [L("跟随系统")])
        LanguageSetting.set("en", in: d)
        #expect(ticked() == ["English"])
    }

    @Test("LG4 choosing a language stores it and offers to reopen; confirming reopens, declining doesn't")
    func choose() throws {
        let (d, name) = freshDomain()
        var asked: [String?] = [], relaunched = 0, answer = false
        let c = LanguageMenuController(defaults: d, domain: name, confirmRestart: { asked.append($0); return answer },
                                       relaunch: { relaunched += 1 })
        let japanese = try #require(c.menu.items.first { $0.title == "日本語" })
        c.chooseLanguage(japanese)
        #expect(LanguageSetting.current(d, domain: name) == "ja")
        #expect(asked == ["ja"]); #expect(relaunched == 0, "declined: later")

        answer = true
        let english = try #require(c.menu.items.first { $0.title == "English" })
        c.chooseLanguage(english)
        #expect(LanguageSetting.current(d, domain: name) == "en"); #expect(relaunched == 1)

        c.chooseLanguage(english)                                  // already chosen: nothing to do
        #expect(asked.count == 2); #expect(relaunched == 1)

        let system = try #require(c.menu.items.first { $0.title == L("跟随系统") })
        c.chooseLanguage(system)
        #expect(LanguageSetting.current(d, domain: name) == nil); #expect(asked.last == .some(nil))
    }

    @Test("LG5 the reopen prompt is worded in the language just chosen")
    func promptLanguage() throws {
        for code in ["en", "ja", "zh-Hans"] {
            let bundle = try #require(Localization.bundle(for: code))
            let text = LanguageMenuController.restartPrompt(for: code)
            #expect(text.message == bundle.localizedString(forKey: "重新打开 VideoTool 后切换语言", value: nil, table: nil))
            #expect(text.now == bundle.localizedString(forKey: "现在重新打开", value: nil, table: nil))
        }
        #expect(LanguageMenuController.restartPrompt(for: "en").message != LanguageMenuController.restartPrompt(for: "ja").message)
    }
}

@Suite(.serialized) @MainActor struct LanguageAlertTests {
    @Test("LG6 the reopen alert itself: message, explanation and buttons in the chosen language, Reopen Now first")
    func alert() throws {
        let ja = try #require(Localization.bundle(for: "ja"))
        let alert = LanguageMenuController.makeRestartAlert(for: "ja")
        #expect(alert.messageText == L("重新打开 VideoTool 后切换语言", in: ja))
        #expect(alert.informativeText == L("正在播放的位置会保存。", in: ja))
        #expect(alert.buttons.map(\.title) == [L("现在重新打开", in: ja), L("稍后", in: ja)])
    }

    @Test("LG7 reopening waits for this process to quit, then opens this app (path quoted safely)")
    func relaunchScript() {
        let args = LanguageMenuController.relaunchArguments(pid: 4242, appPath: "/Applications/Video Tool \"x\".app")
        #expect(args.count == 3 && args[0] == "-c")
        #expect(args[1].contains("kill -0 4242"))
        #expect(args[1].contains("/usr/bin/open \"$0\""), "the path is passed as $0, never spliced into the script")
        #expect(args[2] == "/Applications/Video Tool \"x\".app")
    }
}
