import AppKit
import UniformTypeIdentifiers

final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let session: PlaybackSession?
    var engine: MPVEngine? { session?.engine }       // internal: QualityTests read player stats
    let playerView: PlayerView?          // internal for the event-glue tests
    private let resumeStore = ResumePositionStore()
    private let history = WatchHistoryStore()
    private let memory = PlaybackMemory()
    /// The file whose load has been fully handled (settings restored, subtitles attached).
    private(set) var loadedPath: String?
    /// Subtitle timing of the current video, kept here: the player applies changes
    /// asynchronously, so quick Z/X presses must not each start from its stale value.
    private var subtitleDelay = 0.0
    private let skipStore = SkipStore()
    /// The outro of the current file was handled (skipped once per pass).
    private var outroDone = false
    private lazy var resumeTracker = ResumeTracker(storedPosition: { [resumeStore] path in
        resumeStore.position(for: URL(fileURLWithPath: path))
    })
    private var isShutDown = false

    private let controlBar = NSView()
    /// "Add this folder to the library?" card (the app delegate decides when to offer).
    let libraryOffer = LibraryOfferBar()
    /// Progress of AI subtitles over the video (top left).
    let aiCard = AISubtitleCard()
    private let aiPrefs = AISubtitlePreferences()
    private var aiPipeline: AISubtitlePipeline?
    private var aiTask: Task<Void, Never>?
    /// The language dialog is being prepared or shown (⌘T must not open a second one).
    private var aiDialogPending = false
    var isMakingAISubtitles: Bool { aiTask != nil }
    /// The AI subtitles on screen (to redraw them when the band is switched).
    private var aiShown: (srt: URL, display: URL, bilingual: Bool)?
    /// A file was opened here (menu, Finder, drop or library); used for the library offer.
    var onFileOpened: ((URL) -> Void)?
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    let slider: NSSlider = {          // internal: tests click the bar
        let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        s.cell = PlayerSliderCell()
        return s
    }()
    private let speedChip = NSButton(title: "", target: nil, action: nil)
    private let speedStore = PreferredSpeedStore()
    private let audioOutput = AudioOutputPreference()
    /// The speed the user chose (menu, [ ], ⌫); a hold only borrows the player for a while.
    var preferredSpeed: Double { speedStore.speed }
    private var isScrubbing = false
    private var keyMonitor: Any?
    private var currentURL: URL?

    // Step 3: starred moments
    private let bookmarks: BookmarkController?
    private let markers = BookmarkMarkersView()
    private let preview = BookmarkPreviewView()
    private let hover = HoverPreviewer()
    private var hoverTime: Double?
    var previewCard: BookmarkPreviewView { preview }       // tests
    let listPanel = BookmarkListView()    // internal: tests use the list
    private var listWidth: NSLayoutConstraint?
    private let starButton = NSButton(title: "", target: nil, action: nil)
    private let listButton = NSButton(title: "", target: nil, action: nil)
    /// AI subtitles, visible in the control bar (the menu item alone was not found).
    let aiButton = NSButton(title: "", target: nil, action: nil)
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
        if NightMode.isOn { engine?.setNightMode(true) }
        if let engine {                             // and the sound output chosen last time, if it is still there
            let device = audioOutput.resolved(among: engine.audioDevices())
            if device != AudioOutput.followSystem { engine.setAudioDevice(device) }
        }
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
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L("播放"))
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
        speedChip.toolTip = L("选择播放速度")
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
            (starButton, "star", L("打星标（B）"), #selector(toggleBookmark(_:))),
            (listButton, "list.star", L("星标列表（⇧⌘B）"), #selector(toggleBookmarkList(_:))),
            (aiButton, "captions.bubble", L("AI 字幕（⌘T）"), #selector(generateAISubtitles(_:))),
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

        let stack = NSStackView(views: [playButton, timeLabel, slider, durationLabel, speedChip, aiButton, starButton, listButton])
        updateAIButton()
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
            let error = NSTextField(labelWithString: L("播放引擎初始化失败（libmpv）"))
            error.textColor = .systemRed
            error.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(error)
            constraints += [error.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                            error.centerYAnchor.constraint(equalTo: content.centerYAnchor)]
        }
        aiCard.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(aiCard)
        constraints += [
            aiCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            aiCard.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            aiCard.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32),
        ]
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
        markers.onHoverTime = { [weak self] t, x in self?.showHoverPreview(time: t, atMarkerX: x) }
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

    /// Hovering the bar away from stars: the time at once, the frame when grabbed.
    func showHoverPreview(time: Double?, atMarkerX x: CGFloat) {
        hoverTime = time
        guard let time, let content = window?.contentView else {
            if previewing == nil { preview.hide() }
            return
        }
        guard previewing == nil else { return }                 // a star's own preview is showing
        let image = hover.request(time) { [weak self] img in
            guard let self, let now = self.hoverTime, self.previewing == nil,
                  Int(now / HoverPreviewer.step) == Int(time / HoverPreviewer.step) else { return }
            self.preview.showTime(now, image: img)
            self.place(self.preview, atMarkerX: x, in: content)
        }
        preview.showTime(time, image: image)
        place(preview, atMarkerX: x, in: content)
    }

    private func place(_ card: NSView, atMarkerX x: CGFloat, in content: NSView) {
        let anchor = content.convert(NSPoint(x: x, y: markers.bounds.minY), from: markers)
        var frame = card.frame
        frame.origin.x = min(max(anchor.x - frame.width / 2, 6), content.bounds.width - frame.width - 6)
        frame.origin.y = controlBar.frame.maxY + 6
        card.frame = frame
    }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let bookmarks else { return }
        switch bookmarks.toggleAtCurrentTime() {
        case .added(let b)?: playerView?.hud.flash(text: "★ " + TimeFormatting.string(b.time))
        case .undone?: playerView?.hud.flash(text: L("已撤销星标"))
        case .notReady?: playerView?.hud.flash(text: L("正在识别文件…"))
        case .unavailable?: playerView?.hud.flash(text: L("此文件无法打星标"))
        case nil: break
        }
    }

    @objc func nextBookmark(_ sender: Any?) {
        if bookmarks?.jumpToNext() == false { playerView?.hud.flash(text: L("后面没有星标了")) }
    }

    @objc func previousBookmark(_ sender: Any?) {
        if bookmarks?.jumpToPrevious() == false { playerView?.hud.flash(text: L("前面没有星标了")) }
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
                                   accessibilityDescription: state.isPaused ? L("播放") : L("暂停"))
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
        skipOutroIfReached(state)
        resumeTracker.update(state).forEach(apply)
    }

    private func apply(_ action: ResumeTracker.Action) {
        switch action {
        case .save(let path, let position):
            resumeStore.save(position, for: URL(fileURLWithPath: path))
            history.recordProgress(path: path, position: position, duration: engine?.state.duration ?? 0)
        case .clear(let path):
            resumeStore.clear(for: URL(fileURLWithPath: path))
            history.markFinished(path: path, duration: engine?.state.duration ?? 0)
        case .seek(let target): engine?.seek(to: target)
        }
    }

    private func handle(_ event: PlayerEvent) {
        guard let engine else { return }
        switch event {
        case .fileLoaded(let path, let duration):
            // Read before the tracker acts: with the duration not known yet, its resume
            // seek comes later, and the intro must not be skipped in the meantime.
            let resumeAt = ResumePositionStore.resumeTarget(position: resumeStore.position(for: URL(fileURLWithPath: path)),
                                                            duration: duration)
            resumeTracker.fileLoaded(path: path, duration: duration).forEach(apply)
            outroDone = false
            skipIntro(path: path, duration: duration, resumingAt: resumeAt)
            bookmarks?.open(path: path)         // identifies the file off the main thread
            engine.setPaused(false)
            restoreMemory(for: path)
            loadCachedAISubtitles(for: path)
            loadedPath = path
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
        cancelAISubtitles()
        aiShown = nil
        hover.setSource(url.isFileURL ? url.path : nil)
        currentURL = url
        loadedPath = nil
        defer { updateAIButton() }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        engine.load(url)
        window?.makeKeyAndOrderFront(nil)
        onFileOpened?(url)
    }

    /// Idempotent: called from windowWillClose and applicationWillTerminate.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        cancelAISubtitles()
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
    @objc func cycleSubtitle(_ sender: Any?) { perform(.cycleSubtitle) }
    @objc func cycleAudio(_ sender: Any?) { perform(.cycleAudio) }
    @objc func subtitleEarlier(_ sender: Any?) { perform(.subtitleDelay(-0.1)) }
    @objc func subtitleLater(_ sender: Any?) { perform(.subtitleDelay(0.1)) }

    // MARK: intro / outro

    private var skipKey: String? { currentURL.flatMap { $0.isFileURL ? SkipStore.key(for: $0.path) : nil } }

    /// Play › 片头片尾 › 片头到这里结束: for every episode of this series.
    @objc func markIntroEnd(_ sender: Any?) {
        guard let key = skipKey, let t = engine?.state.timePos else { return }
        skipStore.update(key) { $0.introEnd = t }
        playerView?.hud.flash(text: L("片头到 %@ 结束，本系列会自动跳过", TimeFormatting.string(t)))
    }

    @objc func markOutroStart(_ sender: Any?) {
        guard let key = skipKey, let t = engine?.state.timePos else { return }
        skipStore.update(key) { $0.outroStart = t }
        outroDone = true                                  // not right now: from the next pass on
        playerView?.hud.flash(text: L("片尾从 %@ 开始，本系列会自动跳过", TimeFormatting.string(t)))
    }

    @objc func clearSkips(_ sender: Any?) {
        guard let key = skipKey else { return }
        skipStore.clear(key)
        playerView?.hud.flash(text: L("已清除本系列的片头片尾"))
    }

    /// From the start (or resuming before the intro's end): jump past the intro.
    private func skipIntro(path: String, duration: Double, resumingAt resume: Double?) {
        guard let intro = skipStore.skips(for: SkipStore.key(for: path))?.introEnd,
              (resume ?? 0) < intro - 0.5, duration <= 0 || intro < duration - 1 else { return }
        engine?.seek(to: intro)
        playerView?.hud.flash(text: L("已跳过片头"))
    }

    /// Reaching the outro while playing: on to the next episode, or to the end.
    private func skipOutroIfReached(_ state: PlayerState) {
        guard let path = currentURL?.path, state.path == path, !state.isPaused, !outroDone, loadedPath == path,
              let outro = skipStore.skips(for: SkipStore.key(for: path))?.outroStart, state.timePos >= outro else { return }
        outroDone = true
        playerView?.hud.flash(text: L("已跳过片尾"))
        if let next = SeriesNavigator.nextEpisode(after: path) {
            open(URL(fileURLWithPath: next))
        } else {
            engine?.seek(to: max(state.duration - 0.2, 0))
        }
    }

    // MARK: clip export

    /// The stretch Export Clip proposes: between the stars around the playhead.
    func suggestedClipRange() -> ClipRange? {
        guard let engine, loadedPath != nil else { return nil }
        return ClipRange.suggested(position: engine.state.timePos,
                                   stars: bookmarks?.bookmarks.map(\.time) ?? [], duration: engine.state.duration)
    }

    /// The AI subtitles on screen, as displayed (.ass), for burning into an exported clip.
    var clipSubtitleFile: URL? {
        aiShown.flatMap { FileManager.default.fileExists(atPath: $0.display.path) ? $0.display : nil }
    }

    /// Play › 导出片段…: start and end (prefilled from the stars), format, then where.
    @objc func exportClip(_ sender: Any?) {
        guard let window, let source = currentURL, source.isFileURL, let range = suggestedClipRange() else { return }
        let duration = engine?.state.duration ?? 0
        let startField = NSTextField(string: TimeFormatting.string(range.start))
        let endField = NSTextField(string: range.end >= duration - 0.05 && duration > 0
                                   ? TimeFormatting.string(duration.rounded(.up)) : TimeFormatting.string(range.end))
        let formats: [(String, ClipExporter.Format, String)] = [
            (L("视频（MP4）"), .video, "mp4"), (L("动图（GIF）"), .gif, "gif"), (L("截图组（8 张 JPEG）"), .stills(count: 8), ""),
        ]
        let popup = NSPopUpButton()
        popup.addItems(withTitles: formats.map(\.0))
        let subtitles = clipSubtitleFile
        let withSubtitles = NSButton(checkboxWithTitle: L("带上 AI 字幕"), target: nil, action: nil)
        withSubtitles.state = subtitles != nil ? .on : .off
        withSubtitles.isEnabled = subtitles != nil
        if subtitles == nil { withSubtitles.toolTip = L("先用 AI 字幕（⌘T）生成字幕，就能带进片段里") }
        let grid = NSGridView(views: [[NSTextField(labelWithString: L("开始")), startField],
                                      [NSTextField(labelWithString: L("结束")), endField],
                                      [NSTextField(labelWithString: L("格式")), popup],
                                      [NSGridCell.emptyContentView, withSubtitles]])
        grid.frame = NSRect(x: 0, y: 0, width: 280, height: 120)
        startField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let alert = NSAlert()
        alert.messageText = L("导出片段")
        alert.informativeText = L("默认是播放位置前后两颗星之间的部分。")
        alert.accessoryView = grid
        alert.addButton(withTitle: L("导出…"))
        alert.addButton(withTitle: L("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let format = formats[max(0, popup.indexOfSelectedItem)]
            guard let s = TimeFormatting.parse(startField.stringValue), let e = TimeFormatting.parse(endField.stringValue) else {
                self.playerView?.hud.flash(text: L("时间格式不对，例如 1:05")); return
            }
            let chosen = ClipRange(start: s, end: duration > 0 ? min(e, duration) : e)
            if let problem = chosen.problem(duration: duration, format: format.1) {
                self.playerView?.hud.flash(text: problem); return
            }
            let stem = source.deletingPathExtension().lastPathComponent + " " +
                TimeFormatting.string(chosen.start).replacingOccurrences(of: ":", with: "-")
            let panel = NSSavePanel()
            panel.nameFieldStringValue = format.2.isEmpty ? stem : stem + "." + format.2
            panel.directoryURL = source.deletingLastPathComponent()
            if !format.2.isEmpty { panel.allowedContentTypes = [.init(filenameExtension: format.2) ?? .data] }
            DispatchQueue.main.async {
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    self.runClipExport(source: source, range: chosen, format: format.1,
                                       subtitles: withSubtitles.state == .on ? subtitles : nil, to: url)
                }
            }
        }
    }

    /// Shows exported files; tests replace it so no Finder window opens.
    var revealExported: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    func runClipExport(source: URL, range: ClipRange, format: ClipExporter.Format, subtitles: URL?, to url: URL) {
        playerView?.hud.flash(text: L("正在导出片段…"))
        Task { @MainActor [weak self] in
            do {
                let files = try await ClipExporter.export(source: source, range: range, format: format, subtitles: subtitles, to: url,
                                                          progress: { f in
                    DispatchQueue.main.async { [weak self] in
                        self?.playerView?.hud.flash(text: L("正在导出片段… %@", "\(Int(f * 100))%"))
                    }
                })
                self?.playerView?.hud.flash(text: L("已导出：%@", files.first?.lastPathComponent ?? ""))
                self?.revealExported(files)
            } catch {
                self?.playerView?.hud.flash(text: L("导出失败：%@", error.localizedDescription))
            }
        }
    }

    // MARK: night mode

    @objc func toggleNightMode(_ sender: Any?) {
        NightMode.isOn.toggle()
        engine?.setNightMode(NightMode.isOn)
        playerView?.hud.flash(text: NightMode.isOn ? L("夜间模式：人声更清楚，轰鸣声更小") : L("夜间模式已关闭"))
    }

    // MARK: per-video memory

    /// Puts this video back the way it was left; videos never touched get the defaults.
    private func restoreMemory(for path: String) {
        let e = memory.entry(for: path)
        subtitleDelay = e?.subtitleDelay ?? 0
        engine?.applyTrackChoice(audio: e?.audioTrack ?? "auto", subtitle: e?.subtitleTrack ?? "auto",
                                 subtitleDelay: subtitleDelay)
    }

    /// After a track switch (the player answers asynchronously): note the choice.
    /// Only embedded subtitle tracks or "off" are kept; AI subtitles come back on their own.
    private func rememberTracks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let engine = self.engine, let path = self.currentURL?.path, engine.state.path == path else { return }
            let aid = engine.property("aid"), sid = engine.property("sid")
            let external = engine.property("current-tracks/sub/external") == "yes"
            self.memory.update(path) { e in
                e.audioTrack = aid
                if sid == "no" || !external { e.subtitleTrack = sid }
            }
        }
    }

    private func changeSubtitleDelay(by d: Double) {
        guard let engine, let path = currentURL?.path else { return }
        let delay = ((subtitleDelay + d) * 10).rounded() / 10
        subtitleDelay = delay
        engine.adjustSubtitleDelay(to: delay)
        playerView?.hud.flash(text: L("字幕延迟 %@ 秒", String(format: "%+.1f", delay)))
        memory.update(path) { $0.subtitleDelay = delay }
    }
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
        case .cycleSubtitle: engine.cycleSubtitle(); rememberTracks()
        case .cycleAudio: engine.cycleAudio(); rememberTracks()
        case .subtitleDelay(let d): changeSubtitleDelay(by: d)
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
        case #selector(chooseSubtitleSize(_:)):
            item.state = (item.representedObject as? Double) == aiPrefs.scale ? .on : .off
            return true
        case #selector(exportAISubtitles(_:)):
            return aiShown != nil
        case #selector(exportClip(_:)):
            return currentURL?.isFileURL == true && loadedPath != nil
        case #selector(toggleNightMode(_:)):
            item.state = NightMode.isOn ? .on : .off
            return engine != nil
        case #selector(markIntroEnd(_:)), #selector(markOutroStart(_:)), #selector(clearSkips(_:)):
            return currentURL?.isFileURL == true
        case #selector(toggleSubtitleBand(_:)):
            item.state = aiPrefs.band ? .on : .off
            return true
        case #selector(generateAISubtitles(_:)):
            guard #available(macOS 26.0, *) else { item.toolTip = L("需要 macOS 26 或更新版本"); return false }
            return currentURL?.isFileURL == true && aiTask == nil && !aiDialogPending
        case #selector(toggleBookmarkList(_:)):
            item.state = listPanel.isHidden ? .off : .on
            return bookmarks != nil
        default:
            return true
        }
    }

    // MARK: sound output

    /// Play › 声音输出: one item per output, the current one ticked.
    func audioOutputItems() -> [NSMenuItem] {
        guard let engine else { return [] }
        let current = engine.property("audio-device") ?? AudioOutput.followSystem
        return AudioOutput.menu(devices: engine.audioDevices(), current: current, target: self,
                                action: #selector(chooseAudioOutput(_:)))
    }

    @objc func chooseAudioOutput(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        audioOutput.device = name
        engine?.setAudioDevice(name)
    }

    // MARK: AI subtitles

    /// Play › AI 字幕…: pick languages, then make subtitles on this Mac and show them.
    @objc func generateAISubtitles(_ sender: Any?) {
        guard #available(macOS 26.0, *), let url = currentURL, url.isFileURL, let window,
              aiTask == nil, !aiDialogPending else { return }
        aiDialogPending = true
        updateAIButton()
        Task { @MainActor [weak self] in
            let sources = await AppleSpeechRecognizer.availableSources()
            guard let self else { return }
            AISubtitleDialog.run(on: window, sources: sources, preferences: self.aiPrefs) { [weak self] choice in
                self?.aiDialogPending = false
                self?.updateAIButton()
                guard let self, let choice, self.currentURL == url else { return }
                let pipeline = AISubtitlePipeline(recognizer: AppleSpeechRecognizer(),
                                                  translator: AppleTranslator(window: { [weak self] in self?.window }))
                self.startAISubtitles(video: url.path, choice: choice, pipeline: pipeline)
            }
        }
    }

    /// Internal so tests can run a job with a fake recogniser.
    func startAISubtitles(video: String, choice: AISubtitleDialog.Choice, pipeline: AISubtitlePipeline) {
        cancelAISubtitles()                       // never two jobs at once
        aiPipeline = pipeline
        aiCard.onCancel = { [weak self] in self?.cancelAISubtitles(showing: L("已取消生成字幕")) }
        aiCard.show(.extracting, 0)
        let request = AISubtitlePipeline.Request(video: video, source: choice.source, target: choice.target,
                                                 startAt: engine?.state.timePos ?? 0)
        let title = Self.subtitleTitle(request, translated: request.target != nil)
        var liveShown = false, liveUpTo = 0.0
        aiTask = Task { @MainActor [weak self] in
            let message: String
            do {
                let out = try await pipeline.run(request, progress: { phase, fraction in
                    DispatchQueue.main.async {
                        guard let self, self.aiPipeline === pipeline, !pipeline.isCancelled else { return }
                        if liveShown, phase == .recognizing || phase == .translating {
                            self.aiCard.showLive(upTo: liveUpTo, fraction: fraction)
                        } else {
                            self.aiCard.show(phase, fraction)
                        }
                    }
                }, partial: { cues in
                    // Subtitles while they are being made: rewrite the live file, show or reload it.
                    DispatchQueue.main.async {
                        guard let self, self.aiPipeline === pipeline, !pipeline.isCancelled,
                              self.currentURL?.path == video, let engine = self.engine else { return }
                        try? ASS.document(cues, band: self.aiPrefs.band, scale: self.aiPrefs.scale)
                            .write(to: pipeline.liveFile, atomically: true, encoding: .utf8)
                        if liveShown { engine.reloadSubtitle(path: pipeline.liveFile.path) }
                        else { engine.addSubtitle(path: pipeline.liveFile.path, title: title); liveShown = true }
                        liveUpTo = cues.last?.end ?? 0
                        let duration = engine.state.duration
                        self.aiCard.showLive(upTo: liveUpTo, fraction: duration > 0 ? liveUpTo / duration : 0)
                    }
                })
                // A job that was cancelled or replaced must not touch the current one.
                guard let self, self.aiPipeline === pipeline else { return }
                self.removeLiveSubtitles(of: pipeline)
                guard self.currentURL?.path == video else { return }
                self.showAISubtitles(srt: out.srt, bilingual: request.target != nil && !out.translationSkipped,
                                     title: Self.subtitleTitle(request, translated: !out.translationSkipped))
                message = out.translationSkipped ? AISubtitleError.translationUnavailable.message
                                                 : L("字幕已生成，共 %@ 句（按 S 可切换字幕）", String(describing: out.cueCount))
            } catch let error as AISubtitleError {
                guard error != .cancelled else { return }
                message = error.message
            } catch {
                message = AISubtitleError.failed(error.localizedDescription).message
            }
            guard let self, self.aiPipeline === pipeline else { return }
            self.removeLiveSubtitles(of: pipeline)
            self.aiCard.finish(message)
            self.aiTask = nil
            self.aiPipeline = nil
            self.updateAIButton()
        }
        updateAIButton()
    }

    /// On with a local file open, nothing running and no dialog showing (macOS 26+).
    private func updateAIButton() {
        let item = NSMenuItem(title: "", action: #selector(generateAISubtitles(_:)), keyEquivalent: "")
        aiButton.isEnabled = validateMenuItem(item)
        if #unavailable(macOS 26.0) { aiButton.toolTip = L("需要 macOS 26 或更新版本") }
    }

    /// Takes the subtitles-in-progress off screen and deletes their file.
    private func removeLiveSubtitles(of pipeline: AISubtitlePipeline) {
        engine?.removeSubtitle(path: pipeline.liveFile.path)
        try? FileManager.default.removeItem(at: pipeline.liveFile)
    }

    /// Stops a running job (new file, window closing, or 取消).
    func cancelAISubtitles(showing message: String? = nil) {
        guard aiTask != nil else { return }
        if let pipeline = aiPipeline { removeLiveSubtitles(of: pipeline) }
        aiPipeline?.cancel()
        aiTask?.cancel()
        aiTask = nil
        aiPipeline = nil
        if let message { aiCard.finish(message) } else { aiCard.hide() }
        updateAIButton()
    }

    /// Subtitles made earlier for this file (same languages as last time) come back by themselves.
    private func loadCachedAISubtitles(for path: String) {
        let source = aiPrefs.source
        let target = aiPrefs.target.flatMap { SubtitleLanguages.sameLanguage(source, $0) ? nil : $0 }
        for (t, translated) in [(target, target != nil), (nil, false)] {
            let url = SubtitleCache.url(forVideo: path, source: source, target: t)
            if FileManager.default.fileExists(atPath: url.path) {
                let request = AISubtitlePipeline.Request(video: path, source: source, target: t)
                // Switched on unless the viewer had chosen other subtitles (or none) for this video.
                showAISubtitles(srt: url, bilingual: translated, title: Self.subtitleTitle(request, translated: translated),
                                select: memory.entry(for: path)?.subtitleTrack == nil)
                return
            }
        }
    }

    /// Shows finished AI subtitles through their .ass (with or without the band).
    private func showAISubtitles(srt: URL, bilingual: Bool, title: String, select: Bool = true) {
        guard let engine, let display = SubtitleCache.display(for: srt, bilingual: bilingual, band: aiPrefs.band,
                                                               scale: aiPrefs.scale) else { return }
        engine.addSubtitle(path: display.path, title: title, select: select)
        aiShown = (srt, display, bilingual)
    }

    /// Play › AI 字幕背景条: on by default; redraws the subtitles on screen right away.
    @objc func toggleSubtitleBand(_ sender: Any?) {
        aiPrefs.band.toggle()
        redrawAISubtitles()
    }

    /// Play › AI 字幕大小 › 小 / 中 / 大 (the item carries the scale).
    @objc func chooseSubtitleSize(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        aiPrefs.scale = scale
        redrawAISubtitles()
    }

    private func redrawAISubtitles() {
        guard let shown = aiShown, let engine else { return }
        SubtitleCache.display(for: shown.srt, bilingual: shown.bilingual, band: aiPrefs.band, scale: aiPrefs.scale)
        engine.reloadSubtitle(path: shown.display.path)
    }

    /// Default name for an export: the video's name with .srt, which players pick up by themselves.
    var suggestedExportName: String? {
        currentURL.map { $0.deletingPathExtension().lastPathComponent + ".srt" }
    }

    /// Writes the AI subtitles on screen as .srt (bilingual if translated).
    func exportAISubtitles(to url: URL) throws {
        guard let shown = aiShown else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: shown.srt, to: url)
    }

    /// Play › 导出 AI 字幕…: saves next to the video by default.
    @objc func exportAISubtitles(_ sender: Any?) {
        guard aiShown != nil, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedExportName ?? "subtitles.srt"
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.exportAISubtitles(to: url) } catch { NSSound.beep() }
        }
    }

    static func subtitleTitle(_ r: AISubtitlePipeline.Request, translated: Bool) -> String {
        let from = SubtitleLanguages.sources.first { $0.id == r.source }?.name ?? r.source
        guard translated, let t = r.target else { return L("AI 字幕（%@）", String(describing: from)) }
        let to = SubtitleLanguages.targets.first { $0.id == t }?.name ?? t
        return L("AI 字幕（%1$@ → %2$@）", String(describing: from), String(describing: to))
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
