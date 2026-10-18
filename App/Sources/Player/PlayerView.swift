import AppKit
import UniformTypeIdentifiers

/// Hosts the mpv render layer, the HUD, the idle placeholder, and turns mouse
/// input into the hold-and-drag speed gesture. Keyboard goes to the window.
final class PlayerView: NSView {
    let renderLayer: MPVRenderLayer
    let hud = SpeedHUDView()
    private let placeholder = NSTextField(labelWithString: "拖入视频，或按 ⌘O 打开")
    private(set) var gesture: SpeedGestureController!
    var onFilesDropped: (([URL]) -> Void)?

    init(session: PlaybackSession) {
        renderLayer = session.renderLayer
        let engine = session.engine
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        wantsLayer = true                      // layer-backed; backing layer comes from makeBackingLayer()
        layerContentsRedrawPolicy = .duringViewResize

        gesture = SpeedGestureController(engine: engine, hud: hud, mouseX: { [weak self] in
            guard let self, let window = self.window else { return nil }
            return self.convert(window.mouseLocationOutsideOfEventStream, from: nil).x
        })

        placeholder.font = .systemFont(ofSize: 18, weight: .medium)
        placeholder.textColor = NSColor.white.withAlphaComponent(0.7)
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)

        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        gesture.mouseDown()
    }
    override func mouseDragged(with event: NSEvent) { /* position is polled by the gesture tick */ }
    override func mouseUp(with event: NSEvent) { gesture.mouseUp() }

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
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return objects.filter(MediaTypes.isMedia)
    }
}
