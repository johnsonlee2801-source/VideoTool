import AppKit

/// Small card over the video while AI subtitles are made: what is happening,
/// a progress bar and 取消; afterwards a short result line.
final class AISubtitleCard: NSView {
    static let resultSeconds: TimeInterval = 5

    var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton(title: L("取消"), target: nil, action: nil)
    private let stack = NSStackView()
    private var hideTimer: Timer?

    var message: String { label.stringValue }
    var fraction: Double { bar.doubleValue }
    var isCancellable: Bool { !cancelButton.isHidden }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = Theme.radiusCard
        layer?.borderWidth = 1
        layer?.borderColor = Theme.stroke.cgColor
        isHidden = true

        label.textColor = Theme.textPrimary
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.widthAnchor.constraint(equalToConstant: 140).isActive = true
        LibraryOfferBar.style(cancelButton, primary: false, symbol: "xmark")
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.refusesFirstResponder = true

        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        stack.setViews([label, bar, cancelButton], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Overall progress: extraction is quick, recognition is most of the work.
    func show(_ phase: AISubtitlePipeline.Phase, _ fraction: Double) {
        hideTimer?.invalidate()
        let (text, from, to): (String, Double, Double) = {
            switch phase {
            case .extracting: return (L("正在读取声音…"), 0, 0.1)
            case .recognizing: return (L("AI 正在听写字幕…"), 0.1, 0.8)
            case .translating: return (L("正在翻译字幕…"), 0.8, 1)
            case .done: return (L("字幕已生成"), 1, 1)
            }
        }()
        label.stringValue = text
        bar.doubleValue = from + (to - from) * min(max(fraction, 0), 1)
        bar.isHidden = false
        cancelButton.isHidden = false
        isHidden = false
    }

    /// While subtitles are already showing: how far they reach, and the overall bar.
    func showLive(upTo seconds: Double, fraction: Double) {
        hideTimer?.invalidate()
        label.stringValue = L("字幕生成中 · 已到 %@（可以边看边等）", TimeFormatting.string(seconds))
        bar.doubleValue = 0.1 + 0.9 * min(max(fraction, 0), 1)
        bar.isHidden = false
        cancelButton.isHidden = false
        isHidden = false
    }

    /// A final line (success or why it failed); hides itself after a few seconds.
    func finish(_ text: String) {
        label.stringValue = text
        bar.isHidden = true
        cancelButton.isHidden = true
        isHidden = false
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.resultSeconds, repeats: false) { [weak self] _ in
            self?.isHidden = true
        }
    }

    func hide() {
        hideTimer?.invalidate()
        isHidden = true
    }

    @objc private func cancelPressed() { onCancel?() }
}

/// "AI 字幕" dialog: the video's language and the language to translate into.
enum AISubtitleDialog {
    struct Choice: Equatable {
        var source: String
        var target: String?
    }

    /// Builds the two pop-ups (also used by tests).
    static func popups(sources: [SubtitleLanguages.Choice], source: String, target: String?)
        -> (source: NSPopUpButton, target: NSPopUpButton) {
        let src = NSPopUpButton()
        for s in sources {
            src.addItem(withTitle: s.name)
            src.lastItem?.representedObject = s.id
        }
        src.selectItem(at: max(sources.firstIndex { $0.id == source } ?? 0, 0))
        let tgt = NSPopUpButton()
        for t in SubtitleLanguages.targets {
            tgt.addItem(withTitle: t.name)
            tgt.lastItem?.representedObject = t.id
        }
        tgt.menu?.addItem(.separator())
        tgt.addItem(withTitle: L("不翻译（只要原文）"))
        tgt.lastItem?.representedObject = AISubtitlePreferences.noTranslation
        let wanted = target ?? AISubtitlePreferences.noTranslation
        tgt.selectItem(at: tgt.itemArray.firstIndex { ($0.representedObject as? String) == wanted } ?? 0)
        return (src, tgt)
    }

    static func choice(from popups: (source: NSPopUpButton, target: NSPopUpButton)) -> Choice {
        let source = popups.source.selectedItem?.representedObject as? String ?? "en-US"
        let target = popups.target.selectedItem?.representedObject as? String
        return Choice(source: source, target: target == AISubtitlePreferences.noTranslation ? nil : target)
    }

    /// Modal sheet on `window`; `completion(nil)` when cancelled.
    static func run(on window: NSWindow, sources: [SubtitleLanguages.Choice], preferences: AISubtitlePreferences,
                    completion: @escaping (Choice?) -> Void) {
        let p = popups(sources: sources, source: preferences.source, target: preferences.target)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("视频里说的是：")), p.source],
            [NSTextField(labelWithString: L("翻译成：")), p.target],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 64)

        let alert = NSAlert()
        alert.messageText = L("生成 AI 字幕")
        alert.informativeText = L("在这台 Mac 上离线完成，视频和声音不会上传。第一次使用某种语言时，系统会自动下载语音模型。")
        alert.accessoryView = grid
        alert.addButton(withTitle: L("开始"))
        alert.addButton(withTitle: L("取消"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            let c = choice(from: p)
            preferences.source = c.source
            preferences.target = c.target
            completion(c)
        }
    }
}
