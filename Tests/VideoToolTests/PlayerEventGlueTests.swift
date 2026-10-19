import AppKit
import Testing
@testable import VideoTool

// The AppKit glue between real events and the gesture / key routing logic, which
// the pure suites (SpeedGestureControllerTests, KeyRouterTests) cannot reach:
// the player window's key monitor body and PlayerView's mouse and drop handling.
@Suite(.serialized) @MainActor struct PlayerEventGlueTests {
    private func makeWindow() throws -> (PlayerWindowController, NSWindow, PlayerView) {
        let w = PlayerWindowController()
        let window = try #require(w.window)
        let view = try #require(w.playerView, "no playback session in this environment")
        window.orderBack(nil)                    // gives the window a number events can address
        return (w, window, view)
    }

    private func key(_ chars: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow?) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    private func mouse(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 200, y: 200), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test("G1 mouse down on the video starts the gesture and takes keyboard focus; mouse up ends it")
    func mouseDrivesGesture() throws {
        let (w, window, view) = try makeWindow()
        defer { w.shutdown() }
        let field = NSTextField()
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)                       // e.g. editing a star note
        view.mouseDown(with: mouse(.leftMouseDown, in: window))
        #expect(view.gesture.isActive)
        #expect(window.firstResponder === view)
        view.mouseUp(with: mouse(.leftMouseUp, in: window))
        #expect(!view.gesture.isActive)
    }

    @Test("G2 a plain key while the button is down only cancels the gesture and is swallowed")
    func plainKeyCancels() throws {
        let (w, window, view) = try makeWindow()
        defer { w.shutdown() }
        view.mouseDown(with: mouse(.leftMouseDown, in: window))
        #expect(w.handleKeyDown(key(" ", 49, in: window)) == nil)
        #expect(!view.gesture.isActive)
        view.mouseUp(with: mouse(.leftMouseUp, in: window))  // the later release must not count as a tap
        #expect(!view.gesture.isActive)
    }

    @Test("G3 a ⌘ chord while the button is down cancels the gesture and still reaches the menus")
    func chordCancelsAndPasses() throws {
        let (w, window, view) = try makeWindow()
        defer { w.shutdown() }
        view.mouseDown(with: mouse(.leftMouseDown, in: window))
        let q = key("q", 12, .command, in: window)
        #expect(w.handleKeyDown(q) === q)
        #expect(!view.gesture.isActive)
    }

    @Test("G4 idle: player keys are used, unknown keys pass on")
    func idleKeys() throws {
        let (w, window, _) = try makeWindow()
        defer { w.shutdown() }
        #expect(w.handleKeyDown(key(" ", 49, in: window)) == nil)          // play / pause
        let z = key("q", 12, in: window)          // Q has no player command (Z moves subtitles since 2026-10-19)
        #expect(w.handleKeyDown(z) === z)
    }

    @Test("G5 typing in a text field: every key goes to the field, even player keys")
    func editingTextOwnsKeys() throws {
        let (w, window, _) = try makeWindow()
        defer { w.shutdown() }
        let field = NSTextField()
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(window.firstResponder is NSText)                          // the field editor
        let space = key(" ", 49, in: window)
        #expect(w.handleKeyDown(space) === space)
    }

    @Test("G6 keys meant for another window are left alone") func otherWindow() throws {
        let (w, _, view) = try makeWindow()
        defer { w.shutdown() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderBack(nil)
        defer { other.orderOut(nil) }
        view.gesture.mouseDown()
        let space = key(" ", 49, in: other)
        #expect(w.handleKeyDown(space) === space)
        #expect(view.gesture.isActive, "a key in another window must not cancel this window's gesture")
        view.gesture.mouseUp()
    }

    @Test("G7 the window losing focus cancels the gesture") func resignKeyCancels() throws {
        let (w, window, view) = try makeWindow()
        defer { w.shutdown() }
        view.mouseDown(with: mouse(.leftMouseDown, in: window))
        w.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(!view.gesture.isActive)
    }

    @Test("G8 dropping files: only playable files are accepted, links and documents are ignored")
    func dropFilter() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("VideoToolTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let urls: [NSURL] = [NSURL(fileURLWithPath: "/tmp/a.mkv"), NSURL(fileURLWithPath: "/tmp/notes.txt"),
                             NSURL(string: "https://example.com/v.mp4")!, NSURL(fileURLWithPath: "/tmp/b.MP4")]
        board.writeObjects(urls)
        #expect(PlayerView.mediaURLs(on: board).map(\.lastPathComponent) == ["a.mkv", "b.MP4"])
        board.clearContents()
        #expect(PlayerView.mediaURLs(on: board).isEmpty)
    }
}
