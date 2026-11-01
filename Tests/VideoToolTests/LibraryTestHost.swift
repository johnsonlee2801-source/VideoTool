import AppKit
@testable import VideoTool

/// A window is an explicit test fixture, never part of production library setup.
/// Inherits the real embedded browser so all old action tests exercise its code.
@MainActor final class LibraryTestHost: LibraryBrowserViewController {
    private var host: NSWindow?
    let model: LibraryController
    override var window: NSWindow? { host }
    override init(controller: LibraryController, onOpen: @escaping (URL) -> Void) {
        model = controller
        super.init(controller: controller, onOpen: onOpen)
        showFolderBrowsing(false) // Explicitly exercise the retained "more organization" surface.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view
        self.host = host
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func showWindow(_ sender: Any?) { host?.orderBack(nil); refreshFromStore() }
    func windowDidBecomeKey(_ notification: Notification) { refreshFromStore() }
    func windowWillClose(_ notification: Notification) { model.cancelScan(); shutdown() }
}
