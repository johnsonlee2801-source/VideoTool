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

@Suite(.serialized) @MainActor struct PlayerContextMenuTests {
    private func menu(_ controller: PlayerWindowController) throws -> NSMenu {
        let view = try #require(controller.playerView)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return try #require(view.menu(for: event), "right-click on the picture must offer the player's features")
    }

    private func actions(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            if let submenu = item.submenu { return actions(in: submenu) }
            return item.action == nil ? [] : [item]
        }
    }

    @Test("CM1 right-click exposes speed, AI subtitles and clipping; unavailable actions are disabled")
    func threeFeatures() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let menu = try menu(w)
        #expect(menu.item(withTitle: L("播放速度"))?.submenu != nil)
        #expect(menu.item(withTitle: L("AI 字幕…"))?.action == #selector(PlayerWindowController.generateAISubtitles(_:)))
        let clips = try #require(menu.item(withTitle: L("截取片段"))?.submenu)
        #expect(clips.item(withTitle: L("标记片段起点   C"))?.action == #selector(PlayerWindowController.markClip(_:)))
        #expect(clips.item(withTitle: L("导出片段…"))?.action == #selector(PlayerWindowController.exportClip(_:)))
        let commands = actions(in: menu)
        #expect(!commands.isEmpty)
        #expect(commands.allSatisfy { !$0.isEnabled }, "opening an empty player must not offer unusable actions")
        #expect(commands.allSatisfy { $0.target === w }, "actions belong to the window that was right-clicked")
    }

    @Test("CM2 opening the context menu cancels a left-button hold without starting a new gesture")
    func contextCancelsHold() throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        let view = try #require(w.playerView)
        view.gesture.mouseDown()
        #expect(view.gesture.isActive)
        _ = try menu(w)
        #expect(!view.gesture.isActive)
        #expect(w.window?.firstResponder === view)
        view.gesture.mouseUp()
        #expect(!view.gesture.isActive)
    }

    @Test("CM3 rebuilding the context menu reflects the chosen speed, independently for each window")
    func currentSpeed() throws {
        let first = PlayerWindowController(), second = PlayerWindowController()
        defer { first.shutdown(); second.shutdown(); first.perform(.setSpeed(1)) }
        first.perform(.setSpeed(1.5))
        let speeds = try #require(try menu(first).item(withTitle: L("播放速度"))?.submenu)
        #expect(speeds.items.filter { $0.state == .on }.map(\.title) == ["1.5×"])
        #expect(actions(in: try menu(second)).allSatisfy { $0.target === second })
        first.perform(.setSpeed(2.5))
        let updated = try #require(try menu(first).item(withTitle: L("播放速度"))?.submenu)
        #expect(updated.items.filter { $0.state == .on }.map(\.title) == ["2.5×"])
    }
}

/// Only the macOS fullscreen transition is replaced here. Mouse routing,
/// layout and pause/speed properties use the real views and libmpv engine.
@MainActor private final class FullscreenBoundaryWindow: NSWindow {
    private(set) var fullscreenRequested = false
    override func toggleFullScreen(_ sender: Any?) { fullscreenRequested.toggle() }
}

@Suite(.serialized) @MainActor struct PlayerDoubleClickTests {
    private func player() throws -> (PlayerWindowController, FullscreenBoundaryWindow, PlayerView) {
        let w = PlayerWindowController()
        let old = try #require(w.window)
        let content = try #require(old.contentView)
        let view = try #require(w.playerView)
        let window = FullscreenBoundaryWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        old.delegate = nil
        old.contentView = nil
        old.orderOut(nil)
        window.contentView = content
        w.window = window
        window.delegate = w
        window.orderBack(nil)
        return (w, window, view)
    }

    private func mouse(_ type: NSEvent.EventType, count: Int, in window: NSWindow,
                       timestamp: Double = 0) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 200), modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }

    private func click(_ view: NSView, count: Int, in window: NSWindow) {
        view.mouseDown(with: mouse(.leftMouseDown, count: count, in: window))
        view.mouseUp(with: mouse(.leftMouseUp, count: count, in: window))
    }

    private func wait(_ seconds: Double = 2, until condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test("DC1 picture double-click restores the state before its immediate first tap", arguments: [false, true])
    func togglesFullscreen(initiallyPaused: Bool) async throws {
        let (w, window, view) = try player()
        defer { w.shutdown() }
        let engine = try #require(w.engine)
        let original = initiallyPaused ? "yes" : "no"
        let tapped = initiallyPaused ? "no" : "yes"
        engine.setPaused(initiallyPaused)
        #expect(try await wait { engine.property("pause") == original })
        click(view, count: 1, in: window)
        try await Task.sleep(for: .seconds(min(0.05, NSEvent.doubleClickInterval / 4)))
        #expect(engine.property("pause") == tapped, "the first click takes effect without the double-click wait")
        click(view, count: 2, in: window)
        #expect(window.fullscreenRequested)
        #expect(!view.gesture.isActive)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(engine.property("pause") == original, "the second click restores the state before the pair")
        click(view, count: 3, in: window)
        #expect(window.fullscreenRequested, "an odd third click is not another fullscreen toggle")
        click(view, count: 4, in: window)
        #expect(!window.fullscreenRequested)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(engine.property("pause") == original)
    }

    @Test("DC2 a picture single-click pauses and resumes before the double-click interval")
    func singleClickStillPauses() async throws {
        let (w, window, view) = try player()
        defer { w.shutdown() }
        let engine = try #require(w.engine)
        engine.setPaused(false)
        #expect(try await wait { engine.property("pause") == "no" })
        click(view, count: 1, in: window)
        try await Task.sleep(for: .seconds(min(0.05, NSEvent.doubleClickInterval / 4)))
        #expect(engine.property("pause") == "yes")
        click(view, count: 1, in: window)
        try await Task.sleep(for: .seconds(min(0.05, NSEvent.doubleClickInterval / 4)))
        #expect(engine.property("pause") == "no")
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(engine.property("pause") == "no", "no late toggle may follow either click")
        #expect(!window.fullscreenRequested)
    }

    @Test("DC7 rapid picture double-clicks restore playback before queued state notifications", arguments: [false, true])
    func rapidDoubleClick(initiallyPaused: Bool) async throws {
        let (w, window, view) = try player()
        defer { w.shutdown() }
        let engine = try #require(w.engine)
        let original = initiallyPaused ? "yes" : "no"
        engine.setPaused(initiallyPaused)
        #expect(try await wait { engine.property("pause") == original })
        click(view, count: 1, in: window)
        click(view, count: 2, in: window)
        #expect(window.fullscreenRequested && !view.gesture.isActive)
        #expect(try await wait { engine.property("pause") == original })
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(engine.property("pause") == original)
    }

    @Test("DC8 a recognized picture double-click restores pause even when its second event is delivered late", arguments: [false, true])
    func queuedDoubleClick(initiallyPaused: Bool) async throws {
        let (w, window, view) = try player()
        defer { w.shutdown() }
        let engine = try #require(w.engine)
        let original = initiallyPaused ? "yes" : "no"
        let tapped = initiallyPaused ? "no" : "yes"
        engine.setPaused(initiallyPaused)
        #expect(try await wait { engine.property("pause") == original })

        let start = ProcessInfo.processInfo.systemUptime
        let gap = min(0.05, NSEvent.doubleClickInterval / 4)
        let firstDown = mouse(.leftMouseDown, count: 1, in: window, timestamp: start)
        let firstUp = mouse(.leftMouseUp, count: 1, in: window, timestamp: start + gap / 2)
        let secondDown = mouse(.leftMouseDown, count: 2, in: window, timestamp: start + gap)
        let secondUp = mouse(.leftMouseUp, count: 2, in: window, timestamp: start + gap * 1.5)
        view.mouseDown(with: firstDown)
        view.mouseUp(with: firstUp)
        #expect(try await wait { engine.property("pause") == tapped })

        // Preserve the already recognized pair's timestamps while delaying only
        // delivery. This models a busy main queue without blocking the test host.
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        view.mouseDown(with: secondDown)
        view.mouseUp(with: secondUp)
        #expect(window.fullscreenRequested && !view.gesture.isActive)
        #expect(try await wait { engine.property("pause") == original })
    }

    @Test("DC3 double-clicking empty content or control-bar space toggles fullscreen")
    func emptyAreas() throws {
        let (w, window, _) = try player()
        defer { w.shutdown() }
        let content = try #require(window.contentView)
        click(content, count: 2, in: window)
        #expect(window.fullscreenRequested)
        let bar = try #require(w.slider.superview?.superview)
        click(bar, count: 2, in: window)
        #expect(!window.fullscreenRequested)
    }

    @Test("DC4 a key or context menu keeps completed taps and never adds a late toggle")
    func pendingTapCancellation() async throws {
        let (w, window, view) = try player()
        defer { w.shutdown() }
        let engine = try #require(w.engine)
        engine.setPaused(false)
        #expect(try await wait { engine.property("pause") == "no" })
        click(view, count: 1, in: window)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49))
        #expect(w.handleKeyDown(key) == nil)
        #expect(try await wait { engine.property("pause") == "no" })
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(engine.property("pause") == "no", "Space toggles after the completed picture tap")
        click(view, count: 1, in: window)
        _ = view.menu(for: mouse(.rightMouseDown, count: 1, in: window))
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(engine.property("pause") == "yes")
    }

    @Test("DC5 sidebar clicks stay local while picture and control-bar background double-clicks toggle fullscreen")
    func sidebarBackgroundKeepsItsClicks() throws {
        let (w, window, view) = try player()
        defer { w.shutdown() }
        w.toggleBookmarkList(nil)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        func doubleClick(at location: NSPoint, receiver expected: NSView) throws {
            let receiver = try #require(content.hitTest(location))
            #expect(receiver === expected, "dispatch to the actual hit-tested view")
            // Bypass only NSWindow's inactive-app first-click suppression. Keep
            // real hit testing and the receiver's AppKit responder chain intact.
            for count in 1...2 {
                let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                    modifierFlags: [], timestamp: Double(count) * 0.05, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: 1))
                let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                    modifierFlags: [], timestamp: Double(count) * 0.05 + 0.01, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: 1))
                receiver.mouseDown(with: down)
                receiver.mouseUp(with: up)
            }
        }

        let panel = w.listPanel
        #expect(!panel.isHidden && panel.bounds.width > 0)
        let header = panel.convert(NSPoint(x: panel.bounds.maxX - 8, y: panel.bounds.maxY - 8), to: nil)
        try doubleClick(at: header, receiver: panel)
        #expect(!window.fullscreenRequested, "sidebar events must not trigger the player's fullscreen action")

        let picture = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        try doubleClick(at: picture, receiver: view)
        #expect(window.fullscreenRequested, "picture double-click must work through the same dispatch")

        let bar = try #require(w.slider.superview?.superview)
        let background = bar.convert(NSPoint(x: 8, y: 4), to: nil)
        try doubleClick(at: background, receiver: bar)
        #expect(!window.fullscreenRequested, "empty control-bar space must still toggle back")
    }

    @Test("DC6 every sidebar tab excludes its empty header background from native fullscreen")
    func allSidebarTabsExcludeFullscreen() throws {
        let (w, window, _) = try player()
        defer { w.shutdown() }
        let content = try #require(window.contentView)
        for tab in PlayerSidebarTab.allCases {
            w.sidebar.show(tab)
            content.layoutSubtreeIfNeeded()
            let location = w.sidebar.convert(NSPoint(x: 9, y: w.sidebar.bounds.maxY - 4), to: nil)
            let receiver = try #require(content.hitTest(location))
            #expect(receiver === w.sidebar || receiver.isDescendant(of: w.sidebar))
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            receiver.mouseDown(with: event)
            #expect(!window.fullscreenRequested)
        }
    }
}
