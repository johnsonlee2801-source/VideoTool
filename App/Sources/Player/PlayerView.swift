import AppKit
import UniformTypeIdentifiers

/// Empty player surfaces share the native fullscreen action. Controls consume
/// their own clicks, so buttons, sliders and editable text keep their behavior.
class FullscreenClickView: NSView {
    var onDoubleClick: ((NSEvent) -> Void)?

    static func isFullscreenDoubleClick(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown && event.clickCount >= 2 && event.clickCount.isMultiple(of: 2)
            && !event.modifierFlags.contains(.control)
    }

    override func mouseDown(with event: NSEvent) {
        if Self.isFullscreenDoubleClick(event) {
            if let onDoubleClick { onDoubleClick(event) } else { window?.toggleFullScreen(nil) }
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Hosts the mpv render layer, the HUD, the idle placeholder, and turns mouse
/// input into the hold-and-drag speed gesture. Keyboard goes to the window.
final class PlayerView: FullscreenClickView {
    let renderLayer: MPVRenderLayer
    let hud = SpeedHUDView()
    private let placeholder = EmptyStateView()
    private(set) var gesture: SpeedGestureController!
    var onFilesDropped: (([URL]) -> Void)?
    var contextMenuProvider: (() -> NSMenu)?

    init(session: PlaybackSession) {
        renderLayer = session.renderLayer
        let engine = session.engine
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        wantsLayer = true                      // layer-backed; backing layer comes from makeBackingLayer()
        layerContentsRedrawPolicy = .duringViewResize

        gesture = SpeedGestureController(engine: engine, hud: hud, doubleClickInterval: NSEvent.doubleClickInterval,
                                         mouseX: { [weak self] in
            guard let self, let window = self.window else { return nil }
            return self.convert(window.mouseLocationOutsideOfEventStream, from: nil).x
        })

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)

        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor),
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.topAnchor.constraint(equalTo: topAnchor, constant: 24),
        ])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer { renderLayer }

    var showsPlaceholder: Bool {
        get { !placeholder.isHidden }
        set { placeholder.isHidden = !newValue }
    }

    // MARK: layer housekeeping

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderLayer.contentsScale = window?.backingScaleFactor ?? 2
        renderLayer.setNeedsDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: mouse -> gesture

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)      // ends a note edit; keys go back to the player
        if Self.isFullscreenDoubleClick(event) {
            gesture.doubleClick(eventTime: event.timestamp)
            super.mouseDown(with: event)
            return
        }
        gesture.mouseDown(eventTime: event.timestamp)
    }
    override func mouseDragged(with event: NSEvent) { /* position is polled by the gesture tick */ }
    override func mouseUp(with event: NSEvent) { gesture.mouseUp() }

    override func menu(for event: NSEvent) -> NSMenu? {
        gesture.cancel()                      // restore a held speed before any menu action
        window?.makeFirstResponder(self)
        return contextMenuProvider?()
    }

    // MARK: drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedMediaURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedMediaURLs(sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    private func droppedMediaURLs(_ sender: NSDraggingInfo) -> [URL] {
        Self.mediaURLs(on: sender.draggingPasteboard)
    }

    /// The playable files on a drag pasteboard (web links and other files are ignored).
    static func mediaURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return objects.filter(MediaTypes.isMedia)
    }
}
