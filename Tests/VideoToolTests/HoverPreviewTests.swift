import AppKit
import Testing
@testable import VideoTool

// Hovering the progress bar shows the time there and a thumbnail (2026-10-19,
// "can do" list: users expect it from video sites and other players).

private final class Marker {}
private let sample = URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: "testsrc-20s", ofType: "mp4")!)

@MainActor
private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor final class PreviewRig {
    var grabs: [Double] = []
    var scheduled: [() -> Void] = []
    lazy var previewer = HoverPreviewer(grab: { [unowned self] _, t in
        self.grabs.append(t)
        return NSImage(size: NSSize(width: 4, height: 4))
    }, schedule: { [unowned self] _, run in self.scheduled.append(run) }, background: { $0() }, main: { $0() })
    func fire() { let s = scheduled; scheduled = []; s.forEach { $0() } }
}

@Suite(.serialized) @MainActor struct HoverPreviewerTests {
    @Test("HV1 moving fast only renders where the mouse stopped") func latestWins() {
        let r = PreviewRig()
        r.previewer.setSource("/v/a.mp4")
        var shown: [Double] = []
        for t in [10.0, 20, 30] { _ = r.previewer.request(t) { _ in shown.append(t) } }
        r.fire()
        #expect(r.grabs == [30])
        #expect(shown == [30])
    }

    @Test("HV2 a place seen before shows at once (cached in 2 s steps)") func cached() {
        let r = PreviewRig()
        r.previewer.setSource("/v/a.mp4")
        _ = r.previewer.request(30.4) { _ in }
        r.fire()
        #expect(r.previewer.request(31.1) { _ in } != nil, "same 2 s step")
        #expect(r.previewer.request(33) { _ in } == nil)
        #expect(r.grabs == [30])
    }

    @Test("HV3 another file starts fresh; a late image from the old file is not shown") func newFile() {
        let r = PreviewRig()
        r.previewer.setSource("/v/a.mp4")
        var shown = 0
        _ = r.previewer.request(10) { _ in shown += 1 }
        r.previewer.setSource("/v/b.mp4")
        r.fire()
        #expect(shown == 0 && r.grabs.isEmpty, "the old request was dropped")
        _ = r.previewer.request(10) { _ in shown += 1 }
        r.fire()
        #expect(shown == 1)
    }

    @Test("HV4 the bar reports the time under the mouse; a star takes over near it; leaving clears it")
    func markersReportTime() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 52), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let markers = BookmarkMarkersView(frame: NSRect(x: 0, y: 0, width: 400, height: 52))
        window.contentView?.addSubview(markers)
        markers.duration = 100
        markers.bookmarks = [Bookmark(id: UUID(), fileKey: "k", time: 50, endTime: nil, note: "", createdAt: Date())]
        var times: [Double?] = [], stars: [Double?] = []
        markers.onHoverTime = { t, _ in times.append(t) }
        markers.onHover = { b, _ in stars.append(b?.time) }
        func moved(_ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: markers.convert(NSPoint(x: x, y: 26), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        markers.mouseMoved(with: moved(100))
        let first = times.last.flatMap { $0 } ?? -1
        #expect(abs(first - 25) < 0.5, "x 100 of 400 = 25 s")
        markers.mouseMoved(with: moved(200))
        #expect(stars.last == 50 && times.last == .some(nil), "the star's own preview takes over")
        markers.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        #expect(times.last == .some(nil))
    }

    @Test("HV5 in the player: the card shows the time at once and the real frame shortly after") func inPlayer() async throws {
        let w = PlayerWindowController()
        defer { w.shutdown() }
        w.showWindow(nil)
        w.open(sample)
        let engine = try #require(w.engine)
        #expect(await waitUntil { engine.state.duration > 0 })
        w.showHoverPreview(time: 12, atMarkerX: 300)
        #expect(!w.previewCard.isHidden && w.previewCard.text == "0:12")
        #expect(await waitUntil(5) { w.previewCard.hasImage }, "the frame at 0:12 never arrived")
        w.showHoverPreview(time: nil, atMarkerX: 0)
        #expect(w.previewCard.isHidden)
    }
}
