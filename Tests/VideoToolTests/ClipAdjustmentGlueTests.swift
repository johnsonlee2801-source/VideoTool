import AppKit
import Testing
@testable import VideoTool

@Suite(.serialized) @MainActor struct ClipAdjustmentGlueTests {
    @Test("CA3 native marker drag adjusts a clip endpoint while star clicks keep their action")
    func drag() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let markers = BookmarkMarkersView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        window.contentView?.addSubview(markers)
        markers.duration = 20; markers.clipRange = ClipRange(start: 2, end: 8)
        var selection = ClipSelection(); _ = selection.mark(2); _ = selection.mark(8)
        var adjustments = 0, stars = 0
        markers.onClipAdjust = { endpoint, time in adjustments += 1; markers.clipRange = selection.adjust(endpoint, to: time, duration: 20) }
        markers.bookmarks = [Bookmark(id: UUID(), fileKey: "test", time: 2, endTime: nil, note: "", createdAt: Date())]
        markers.onClick = { _ in stars += 1 }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: markers.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        markers.mouseDown(with: try event(.leftMouseDown, 40, 25))
        markers.mouseDragged(with: try event(.leftMouseDragged, 100, 25))
        markers.mouseUp(with: try event(.leftMouseUp, 100, 25))
        #expect(selection.range == ClipRange(start: 5, end: 8) && adjustments == 1)
        markers.clipRange = ClipRange(start: 2, end: 8)
        markers.mouseDown(with: try event(.leftMouseDown, 40, markers.starCenterY))
        #expect(stars == 1 && adjustments == 1)
        markers.mouseDown(with: try event(.leftMouseDown, 40, 25))
        markers.clipRange = nil
        markers.clipRange = ClipRange(start: 2, end: 8)
        markers.mouseDragged(with: try event(.leftMouseDragged, 120, 25))
        #expect(adjustments == 1, "clearing a clip must cancel an old endpoint drag")
        markers.mouseDown(with: try event(.leftMouseDown, 40, 25))
        markers.mouseUp(with: try event(.leftMouseUp, 120, 25))
        #expect(selection.range?.start == 6, "mouse-up must apply the final pointer position even when drag events were coalesced")
    }
    @Test("CA6 clip-time native button exposes the adjustment action")
    func nativeButton() {
        let bar = ClipBar()
        var count = 0
        bar.onAdjust = { count += 1 }
        bar.show(ClipRange(start: 2.25, end: 8))
        bar.adjustButton.performClick(nil)
        #expect(count == 1 && bar.adjustButton.toolTip?.contains("0:02.250") == true)
    }
    @Test("CA4 exact time input, nominal-frame step and fixed-window zoom update the same range")
    func detail() throws {
        var selection = ClipSelection(); _ = selection.mark(2); _ = selection.mark(8)
        let view = ClipAdjustmentView(range: try #require(selection.range), duration: 30, fps: 24) { selection.adjust($0, to: $1, duration: 30) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(view); view.layoutSubtreeIfNeeded()
        view.startField.stringValue = "nan"; view.commit(view.startField)
        #expect(selection.range?.start == 2)
        view.startField.stringValue = "0:03.250"; view.commit(view.startField)
        #expect(selection.range?.start == 3.25)
        view.endStepper.doubleValue += ClipAdjustment.step(fps: 24)
        NSApp.sendAction(view.endStepper.action!, to: view.endStepper.target, from: view.endStepper)
        #expect(abs(view.range.end - (8 + 1.0 / 24)) < 0.000001)
        view.focus.selectedSegment = 0
        NSApp.sendAction(view.focus.action!, to: view.focus.target, from: view.focus)
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: view.zoom.convert(NSPoint(x: x, y: 28), to: nil), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.zoom.mouseDown(with: try event(.leftMouseDown, 10))
        view.zoom.mouseDragged(with: try event(.leftMouseDragged, 300))
        view.zoom.mouseUp(with: try event(.leftMouseUp, 300))
        #expect(abs(view.range.start - 6.25) < 0.000001, "zoom must not recenter while dragging")
    }
}
