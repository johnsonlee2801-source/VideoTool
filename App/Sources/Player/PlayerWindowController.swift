import AppKit
import UniformTypeIdentifiers

final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let session: PlaybackSession?
    private var engine: MPVEngine? { session?.engine }
    let playerView: PlayerView?          // internal for the event-glue tests
    private let resumeStore = ResumePositionStore()
    private lazy var resumeTracker = ResumeTracker(storedPosition: { [resumeStore] path in
        resumeStore.position(for: URL(fileURLWithPath: path))
    })
    private var isShutDown = false

    private let controlBar = NSView()
    /// "Add this folder to the library?" card (the app delegate decides when to offer).
    let libraryOffer = LibraryOfferBar()
    /// A file was opened here (menu, Finder, drop or library); used for the library offer.
    var onFileOpened: ((URL) -> Void)?
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let slider: NSSlider = {
        let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        s.cell = PlayerSliderCell()
        return s
    }()
    private let speedChip = NSButton(title: "", target: nil, action: nil)
    private let speedStore = PreferredSpeedStore()
    /// The speed the user chose (menu, [ ], ⌫); a hold only borrows the player for a while.
    var preferredSpeed: Double { speedStore.speed }
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
    static let listPanelWidth: CGFloat = 300
    static let controlBarHeight: CGFloat = 52

    init() {
        let session = try? PlaybackSession()
        self.session = session
        self.playerView = session.map { PlayerView(session: $0) }
        self.bookmarks = session.flatMap { s in
            (try? BookmarkStore()).map { BookmarkController(store: $0, engine: s.engine) }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720 + Self.controlBarHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "VideoTool"
        window.minSize = NSSize(width: 520, height: 270 + Self.controlBarHeight)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = Theme.bg0
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        if !AppData.isTestRun { window.setFrameAutosaveName("VideoTool.PlayerWindow") }   // tests resize windows
        super.init(window: window)
        window.delegate = self
        buildContent()
        wireEngine()
        engine?.setSpeed(speedStore.speed)          // start at the speed chosen last time
        wireBookmarks()
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: layout

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg0.cgColor
        window.contentView = content

        controlBar.wantsLayer = true
        controlBar.layer?.backgroundColor = Theme.bg1.cgColor
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.stroke.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: controlBar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controlBar)

        playButton.bezelStyle = .texturedRounded
        playButton.isBordered = false
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "播放")
        playButton.symbolConfiguration = .init(pointSize: 17, weight: .black)
        playButton.contentTintColor = Theme.textPrimary
        playButton.target = self
        playButton.action = #selector(togglePause(_:))

        timeLabel.font = Theme.digits(13, .bold)
        timeLabel.textColor = Theme.textPrimary
        durationLabel.font = Theme.digits(13, .semibold)
        durationLabel.textColor = Theme.textSecondary

        speedChip.isBordered = false
        speedChip.wantsLayer = true
        speedChip.layer?.cornerRadius = Theme.radiusSmall
        speedChip.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.18).cgColor
        speedChip.contentTintColor = Theme.accent
        speedChip.font = Theme.digits(12, .heavy)
        speedChip.toolTip = "选择播放速度"
        showSpeed(speedStore.speed)                                  // before the player reports in
        speedChip.setContentHuggingPriority(.required, for: .horizontal)
        speedChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        speedChip.target = self
        speedChip.action = #selector(showSpeedMenu(_:))
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
            button.symbolConfiguration = .init(pointSize: 15, weight: .bold)
            button.contentTintColor = Theme.textPrimary
            button.toolTip = tip
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let stack = NSStackView(views: [playButton, timeLabel, slider, durationLabel, speedChip, starButton, listButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(stack)

        var constraints = [
            controlBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: Self.controlBarHeight),
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
        libraryOffer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(libraryOffer)
        constraints += [
            libraryOffer.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            libraryOffer.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: -16),
            libraryOffer.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ]
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
        markers.onClick = { [weak bookmarks] b in bookmarks?.jump(to: b) }
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
        listButton.contentTintColor = show ? Theme.accent : Theme.textPrimary
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
        showSpeed(state.speed)

        let name = currentURL?.lastPathComponent ?? ""
        let title = state.mediaTitle.isEmpty ? name : state.mediaTitle
        let speed = abs(state.speed - 1.0) > 0.001 ? "  ·  " + PlaybackSpeed.label(state.speed) : ""
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
        libraryOffer.hide()
        currentURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        engine.load(url)
        window?.makeKeyAndOrderFront(nil)
        onFileOpened?(url)
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
    @objc func speedUp(_ sender: Any?) { perform(.speedDelta(0.1)) }
    @objc func speedDown(_ sender: Any?) { perform(.speedDelta(-0.1)) }
    @objc func resetSpeed(_ sender: Any?) { perform(.resetSpeed) }

    /// From the speed label or Play › 播放速度: the item carries its speed.
    @objc func chooseSpeedPreset(_ sender: NSMenuItem) {
        if let speed = sender.representedObject as? Double { perform(.setSpeed(speed)) }
    }

    @objc private func showSpeedMenu(_ sender: NSButton) {
        let menu = PlaybackSpeed.menu(current: preferredSpeed, target: self, action: #selector(chooseSpeedPreset(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The speed label is always shown; highlighted only when not at normal speed.
    private func showSpeed(_ speed: Double) {
        let fast = abs(speed - 1.0) > 0.001
        speedChip.title = PlaybackSpeed.label(speed)
        speedChip.contentTintColor = fast ? Theme.accent : Theme.textSecondary
        speedChip.layer?.backgroundColor = (fast ? Theme.accent.withAlphaComponent(0.18) : Theme.bg2).cgColor
    }

    /// Sets and remembers a chosen speed (not used by the hold gesture).
    private func choose(speed: Double) {
        let s = PlaybackSpeed.normalized(speed)
        speedStore.speed = s
        engine?.setSpeed(s)
    }
    @objc func cycleSubtitle(_ sender: Any?) { engine?.cycleSubtitle() }
    @objc func cycleAudio(_ sender: Any?) { engine?.cycleAudio() }
    @objc func toggleMute(_ sender: Any?) { engine?.toggleMute() }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let engine else { return }
        // Only a drag is "scrubbing". A plain click, the mouse-up, or keyboard
        // changes end it, so the slider always resumes following playback.
        // A click near a star lands 2 s before it (user decision 2026-10-18); see ScrubPolicy.
        let decision = ScrubPolicy.decide(
            isDrag: NSApp.currentEvent?.type == .leftMouseDragged, value: sender.doubleValue,
            duration: engine.state.duration, trackWidth: markers.track().width, snapRadius: Double(Self.snapRadius),
            snap: { [weak self] v, t in self?.bookmarks?.seekTarget(forClickAt: v, tolerance: t) ?? v })
        isScrubbing = decision.isScrubbing
        switch decision.seek {
        case .keyframe(let t): engine.scrub(to: t)
        case .exact(let t): engine.seek(to: t)
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
        // Steps start from the chosen speed (the player's own speed updates asynchronously).
        case .speedDelta(let d): choose(speed: preferredSpeed + d)
        case .resetSpeed: choose(speed: 1.0)
        case .setSpeed(let s): choose(speed: s)
        case .toggleBookmark: toggleBookmark(nil)
        case .previousBookmark: previousBookmark(nil)
        case .nextBookmark: nextBookmark(nil)
        }
    }

    // MARK: snapshot staging (tests only)

    /// Puts the window into a representative state for UI snapshot tests:
    /// a still frame in place of the GL video, stars, a position, optionally the list and a preview.
    func stageForSnapshot(frame: NSImage?, bookmarks list: [Bookmark], duration: Double, position: Double,
                          showList: Bool, previewFirst: Bool, hud: String?) {
        if let frame, let playerView {
            let still = NSImageView(image: frame)
            still.imageScaling = .scaleProportionallyUpOrDown
            still.frame = playerView.bounds
            still.autoresizingMask = [.width, .height]
            playerView.addSubview(still, positioned: .below, relativeTo: nil)
            playerView.showsPlaceholder = false
        }
        slider.maxValue = duration
        slider.doubleValue = position
        slider.isEnabled = true
        timeLabel.stringValue = TimeFormatting.string(position)
        durationLabel.stringValue = TimeFormatting.string(duration)
        playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        markers.duration = duration
        markers.bookmarks = list
        listPanel.show(list)
        if showList && listPanel.isHidden { toggleBookmarkList(nil) }
        window?.contentView?.layoutSubtreeIfNeeded()
        if previewFirst, let b = list.first, let x = markers.x(for: b) { showPreview(b, atMarkerX: x) }
        if let hud { playerView?.hud.show(speed: Double(hud) ?? 2.0, dx: 0) }
    }

    // MARK: menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleBookmark(_:)), #selector(nextBookmark(_:)), #selector(previousBookmark(_:)):
            return bookmarks?.isReady == true
        case #selector(chooseSpeedPreset(_:)):
            item.state = (item.representedObject as? Double).map { abs($0 - preferredSpeed) < 0.001 } == true ? .on : .off
            return engine != nil
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
            self?.handleKeyDown(event) ?? event
        }
    }

    /// The key monitor's body: returns nil if the key was used, else the event to pass on.
    /// Internal so tests can feed it synthesized events.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        let gestureActive = playerView?.gesture.isActive ?? false
        // Any key press while the button is down ends the gesture without a tap.
        if gestureActive { playerView?.gesture.cancel() }
        let editingText = window?.firstResponder is NSText      // typing a star note
        switch KeyRouter.decide(KeyRouter.input(from: event), gestureActive: gestureActive,
                                isEditingText: editingText) {
        case .perform(let command): perform(command); return nil
        case .cancelGestureOnly: return nil
        case .cancelGestureAndPassThrough, .passThrough: return event
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
