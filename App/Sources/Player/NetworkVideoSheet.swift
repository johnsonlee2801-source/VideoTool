import AppKit

/// One compact, cancellable entry point. Resolution never blocks or replaces
/// the current video until a validated result is delivered exactly once.
final class NetworkVideoSheet: NSObject {
    let panel: NSPanel
    let urlField = NSTextField(string: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let openButton = NSButton(title: L("播放"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L("取消"), target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let resolver: YouTubeResolving
    private let onOpen: (ResolvedYouTubeVideo) -> Void
    private var generation = 0
    private var dismissed = false
    private(set) var isResolving = false

    init(resolver: YouTubeResolving = YouTubeResolver(), onOpen: @escaping (ResolvedYouTubeVideo) -> Void) {
        self.resolver = resolver; self.onOpen = onOpen
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = L("打开网络视频")
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = Theme.bg1
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg1.cgColor
        panel.contentView = content
        let title = NSTextField(labelWithString: L("在 VideoTool 中播放 YouTube"))
        title.font = Theme.display(18, .bold); title.textColor = Theme.textPrimary
        let hint = NSTextField(wrappingLabelWithString: L("粘贴公开视频链接；播放列表仅打开当前视频。"))
        hint.font = Theme.display(12, .regular); hint.textColor = Theme.textSecondary
        urlField.placeholderString = "https://www.youtube.com/watch?v=…"
        urlField.font = Theme.display(13, .regular)
        urlField.setAccessibilityLabel(L("YouTube 视频链接"))
        urlField.target = self; urlField.action = #selector(submit(_:))
        status.font = Theme.display(12, .regular); status.textColor = Theme.textSecondary
        status.maximumNumberOfLines = 3
        status.setAccessibilityElement(true)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        openButton.bezelStyle = .rounded; openButton.contentTintColor = Theme.accent
        openButton.target = self; openButton.action = #selector(submit(_:)); openButton.keyEquivalent = "\r"
        cancelButton.bezelStyle = .rounded; cancelButton.target = self; cancelButton.action = #selector(cancelAction(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        for button in [openButton, cancelButton] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = Theme.radiusSmall
            button.layer?.backgroundColor = (button === openButton ? Theme.accent : Theme.bg2).cgColor
            button.font = Theme.display(13, .semibold)
            button.contentTintColor = Theme.textPrimary
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        }
        for view in [title, hint, urlField, status, spinner, openButton, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            urlField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            urlField.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            urlField.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            urlField.heightAnchor.constraint(equalToConstant: 26),
            spinner.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            spinner.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 12),
            spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            status.topAnchor.constraint(equalTo: spinner.topAnchor),
            openButton.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            openButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            cancelButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
        ])
    }

    func present(on window: NSWindow, text: String = "") {
        urlField.stringValue = text
        window.beginSheet(panel)
        panel.makeFirstResponder(urlField)
    }

    @objc func submit(_ sender: Any?) {
        guard !dismissed, !isResolving else { return }
        let request: YouTubeVideo
        do { request = try YouTubeVideo(urlField.stringValue) }
        catch { status.stringValue = YouTubeFailure.invalidLink.localizedDescription; return }
        generation += 1
        let token = generation
        setResolving(true)
        status.stringValue = L("正在解析视频，可随时取消…")
        resolver.resolve(request) { [weak self] result in
            guard let self, !self.dismissed, self.generation == token else { return }
            self.setResolving(false)
            switch result {
            case .success(let media):
                self.cancel()
                self.onOpen(media)
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
        }
    }

    private func setResolving(_ value: Bool) {
        isResolving = value
        openButton.isEnabled = !value
        urlField.isEnabled = !value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    @objc private func cancelAction(_ sender: Any?) { cancel() }
    func cancel() {
        generation += 1; dismissed = true
        resolver.cancel(); setResolving(false)
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
    }
}
