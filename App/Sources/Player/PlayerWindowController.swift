import AppKit
import UniformTypeIdentifiers

final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let session: PlaybackSession?
    private var engine: MPVEngine? { session?.engine }
    private let playerView: PlayerView?
    private let resumeStore = ResumePositionStore()
    private lazy var resumeTracker = ResumeTracker(storedPosition: { [resumeStore] path in
        resumeStore.position(for: URL(fileURLWithPath: path))
    })
    private var isShutDown = false

    private let controlBar = NSView()
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var isScrubbing = false
    private var keyMonitor: Any?
    private var currentURL: URL?

    // Step 3: starred moments
    private let bookmarks: BookmarkController?
    private let markers = BookmarkMarkersView()
    private let preview = BookmarkPreviewView()
    private let listPanel = BookmarkListView()
    private var listWidth: NSLayoutConstraint?
    private let starButton = NSButton(title: "", target: nil, action: nil)
    private let listButton = NSButton(title: "", target: nil, action: nil)
    /// Pixels around a star in which a click on the bar snaps to it.
    private static let snapRadius: CGFloat = 6
    static let listPanelWidth: CGFloat = 280

    init() {
        let session = try? PlaybackSession()
        self.session = session
        self.playerView = session.map { PlayerView(session: $0) }
        self.bookmarks = session.flatMap { s in
            (try? BookmarkStore()).map { BookmarkController(store: $0, engine: s.engine) }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720 + 40),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "VideoTool"
        window.minSize = NSSize(width: 480, height: 270 + 40)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.center()
        window.setFrameAutosaveName("VideoTool.PlayerWindow")
        super.init(window: window)
        window.delegate = self
        buildContent()
        wireEngine()
        wireBookmarks()
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: layout

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content

        controlBar.wantsLayer = true
        controlBar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controlBar)

        playButton.bezelStyle = .texturedRounded
        playButton.isBordered = false
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "播放")
        playButton.contentTintColor = .white
        playButton.target = self
        playButton.action = #selector(togglePause(_:))

        for label in [timeLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = NSColor.white.withAlphaComponent(0.85)
        }
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.isContinuous = true
        slider.controlSize = .small

        for (button, symbol, tip, action) in [
            (starButton, "star", "打星标（B）", #selector(toggleBookmark(_:))),
            (listButton, "list.star", "星标列表（⇧⌘B）", #selector(toggleBookmarkList(_:))),
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.contentTintColor = .white
            button.toolTip = tip
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let stack = NSStackView(views: [playButton, timeLabel, slider, durationLabel, starButton, listButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(stack)

        var constraints = [
            controlBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 28),
        ]

        // Star markers sit exactly over the slider; the preview floats above the bar.
        markers.slider = slider
        markers.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(markers)
        preview.translatesAutoresizingMaskIntoConstraints = true
        constraints += [
            markers.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            markers.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            markers.topAnchor.constraint(equalTo: controlBar.topAnchor),
            markers.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor),
        ]

        listPanel.translatesAutoresizingMaskIntoConstraints = false
        listPanel.isHidden = true
        content.addSubview(listPanel)
        let width = listPanel.widthAnchor.constraint(equalToConstant: 0)
        listWidth = width
        constraints += [
            width,
            listPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listPanel.topAnchor.constraint(equalTo: content.topAnchor),
            listPanel.bottomAnchor.constraint(equalTo: controlBar.topAnchor),
        ]

        if let playerView {
            playerView.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(playerView, positioned: .below, relativeTo: controlBar)
            constraints += [
                playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: listPanel.leadingAnchor),
                playerView.topAnchor.constraint(equalTo: content.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: controlBar.topAnchor),
            ]
            playerView.onFilesDropped = { [weak self] urls in
                if let first = urls.first { self?.open(first) }
            }
            playerView.showsPlaceholder = true
        } else {
            let error = NSTextField(labelWithString: "播放引擎初始化失败（libmpv）")
            error.textColor = .systemRed
            error.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(error)
            constraints += [error.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                            error.centerYAnchor.constraint(equalTo: content.centerYAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
        content.addSubview(preview)            // last: floats above everything, never takes clicks
    }

    // MARK: stars

    private func wireBookmarks() {
        guard let bookmarks else { starButton.isEnabled = false; listButton.isEnabled = false; return }
        bookmarks.onChange = { [weak self] list in
            self?.markers.bookmarks = list
            self?.listPanel.show(list)
        }
        bookmarks.onError = { error in NSLog("bookmarks: %@", "\(error)") }
        listPanel.onJump = { [weak bookmarks] b in bookmarks?.jump(to: b) }
        listPanel.onNoteChange = { [weak bookmarks] id, note in bookmarks?.updateNote(id, note) }
        listPanel.onDelete = { [weak bookmarks] id in bookmarks?.delete(id) }
        bookmarks.onThumbnailReady = { [weak self] id in self?.refreshPreview(ifShowing: id) }
        markers.onHover = { [weak self] b, x in self?.showPreview(b, atMarkerX: x) }
        listPanel.show([])
    }

    private var previewing: (bookmark: Bookmark, x: CGFloat)?

    private func refreshPreview(ifShowing id: UUID) {
        guard let p = previewing, p.bookmark.id == id else { return }
        showPreview(p.bookmark, atMarkerX: p.x)
    }

    private func showPreview(_ b: Bookmark?, atMarkerX x: CGFloat) {
        guard let b, let content = window?.contentView else { previewing = nil; preview.hide(); return }
        previewing = (b, x)
        let anchor = content.convert(NSPoint(x: x, y: markers.bounds.minY), from: markers)
        var frame = preview.frame
        frame.origin.x = min(max(anchor.x - frame.width / 2, 6), content.bounds.width - frame.width - 6)
        frame.origin.y = controlBar.frame.maxY + 6
        preview.frame = frame
        preview.show(b, thumbnail: bookmarks?.thumbnailURL(for: b))
    }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let bookmarks else { return }
        switch bookmarks.toggleAtCurrentTime() {
        case .added(let b)?: playerView?.hud.flash(text: "★ " + TimeFormatting.string(b.time))
        case .undone?: playerView?.hud.flash(text: "已撤销星标")
        case .notReady?: playerView?.hud.flash(text: "正在识别文件…")
        case .unavailable?: playerView?.hud.flash(text: "此文件无法打星标")
        case nil: break
        }
    }

    @objc func nextBookmark(_ sender: Any?) {
        if bookmarks?.jumpToNext() == false { playerView?.hud.flash(text: "后面没有星标了") }
    }

    @objc func previousBookmark(_ sender: Any?) {
        if bookmarks?.jumpToPrevious() == false { playerView?.hud.flash(text: "前面没有星标了") }
    }

    @objc func toggleBookmarkList(_ sender: Any?) {
        let show = listPanel.isHidden
        listPanel.isHidden = !show
        listWidth?.constant = show ? Self.listPanelWidth : 0
        listButton.contentTintColor = show ? .systemYellow : .white
    }

    // MARK: engine wiring

    private func wireEngine() {
        guard let engine else { return }
        engine.onStateChange = { [weak self] state in self?.render(state) }
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    private func render(_ state: PlayerState) {
        guard let window else { return }
        playButton.image = NSImage(systemSymbolName: state.isPaused ? "play.fill" : "pause.fill",
                                   accessibilityDescription: state.isPaused ? "播放" : "暂停")
        if !isScrubbing {
            slider.maxValue = max(state.duration, 0.001)
            slider.doubleValue = min(state.timePos, slider.maxValue)
        }
        timeLabel.stringValue = TimeFormatting.string(state.timePos)
        durationLabel.stringValue = TimeFormatting.string(state.duration)
        slider.isEnabled = state.duration > 0
        if markers.duration != state.duration { markers.duration = state.duration }

        let name = currentURL?.lastPathComponent ?? ""
        let title = state.mediaTitle.isEmpty ? name : state.mediaTitle
        let speed = abs(state.speed - 1.0) > 0.001 ? String(format: "  ·  %.1f×", state.speed) : ""
        window.title = title.isEmpty ? "VideoTool" : title + speed
        playerView?.showsPlaceholder = state.isIdle

        if state.eofReached { playerView?.gesture.cancel() }
        resumeTracker.update(state).forEach(apply)
    }

    private func apply(_ action: ResumeTracker.Action) {
        switch action {
        case .save(let path, let position): resumeStore.save(position, for: URL(fileURLWithPath: path))
        case .clear(let path): resumeStore.clear(for: URL(fileURLWithPath: path))
        case .seek(let target): engine?.seek(to: target)
        }
    }

    private func handle(_ event: PlayerEvent) {
        guard let engine else { return }
        switch event {
        case .fileLoaded(let path, let duration):
            resumeTracker.fileLoaded(path: path, duration: duration).forEach(apply)
            bookmarks?.open(path: path)         // identifies the file off the main thread
            engine.setPaused(false)
        case .endFile:
            // With keep-open, natural EOF does not end the file; eofReached in
            // render() handles that. This fires on replace/stop/errors.
            playerView?.gesture.cancel()
        case .log(let line):
            NSLog("%@", line)
        }
    }

    // MARK: public API

    func open(_ url: URL) {
        guard let engine else { return }
        saveResumeNow()
        bookmarks?.fileClosed()
        preview.hide()
        currentURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        engine.load(url)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Idempotent: called from windowWillClose and applicationWillTerminate.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        saveResumeNow()
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
        playerView?.gesture.cancel()
        session?.shutdown()                    // render context first, then mpv
    }

    private func saveResumeNow() {
        guard let engine, let action = resumeTracker.finalAction(engine.state) else { return }
        apply(action)
    }

    // MARK: actions

    @objc func togglePause(_ sender: Any?) { engine?.togglePause() }
    @objc func seekBack(_ sender: Any?) { engine?.seek(by: -5) }
    @objc func seekForward(_ sender: Any?) { engine?.seek(by: 5) }
    @objc func speedUp(_ sender: Any?) { engine.map { $0.setSpeed($0.state.speed + 0.1) } }
    @objc func speedDown(_ sender: Any?) { engine.map { $0.setSpeed($0.state.speed - 0.1) } }
    @objc func resetSpeed(_ sender: Any?) { engine?.setSpeed(1.0) }
    @objc func cycleSubtitle(_ sender: Any?) { engine?.cycleSubtitle() }
    @objc func cycleAudio(_ sender: Any?) { engine?.cycleAudio() }
    @objc func toggleMute(_ sender: Any?) { engine?.toggleMute() }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let engine else { return }
        // Only a drag is "scrubbing". A plain click, the mouse-up, or keyboard
        // changes end it, so the slider always resumes following playback.
        if NSApp.currentEvent?.type == .leftMouseDragged {
            isScrubbing = true
            engine.scrub(to: sender.doubleValue)          // keyframe seek while dragging
        } else {
            isScrubbing = false
            // A click near a star lands 2 s before it (user decision 2026-10-18).
            let width = max(markers.track().width, 1)     // same geometry the stars are drawn with
            let tolerance = Double(Self.snapRadius) * engine.state.duration / width
            let target = bookmarks?.seekTarget(forClickAt: sender.doubleValue, tolerance: tolerance) ?? sender.doubleValue
            engine.seek(to: target)                       // exact seek for the final position
        }
    }

    func perform(_ command: PlayerCommand) {
        guard let engine else { return }
        switch command {
        case .togglePause: engine.togglePause()
        case .seek(let d): engine.seek(by: d)
        case .volume(let d): engine.setVolume(engine.state.volume + d)
        case .toggleMute: engine.toggleMute()
        case .toggleFullscreen: window?.toggleFullScreen(nil)
        case .cycleSubtitle: engine.cycleSubtitle()
        case .cycleAudio: engine.cycleAudio()
        case .speedDelta(let d): engine.setSpeed(engine.state.speed + d)
        case .resetSpeed: engine.setSpeed(1.0)
        case .toggleBookmark: toggleBookmark(nil)
        case .previousBookmark: previousBookmark(nil)
        case .nextBookmark: nextBookmark(nil)
        }
    }

    // MARK: menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleBookmark(_:)), #selector(nextBookmark(_:)), #selector(previousBookmark(_:)):
            return bookmarks?.isReady == true
        case #selector(toggleBookmarkList(_:)):
            item.state = listPanel.isHidden ? .off : .on
            return bookmarks != nil
        default:
            return true
        }
    }

    // MARK: keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let gestureActive = self.playerView?.gesture.isActive ?? false
            // Any key press while the button is down ends the gesture without a tap.
            if gestureActive { self.playerView?.gesture.cancel() }
            let editingText = self.window?.firstResponder is NSText      // typing a star note
            switch KeyRouter.decide(KeyRouter.input(from: event), gestureActive: gestureActive,
                                    isEditingText: editingText) {
            case .perform(let command): self.perform(command); return nil
            case .cancelGestureOnly: return nil
            case .cancelGestureAndPassThrough, .passThrough: return event
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        playerView?.gesture.cancel()
    }

    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        shutdown()
        onClose?()
    }
}
