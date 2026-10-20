import AppKit
import Testing
@testable import VideoTool

// Clicking a star (reported 2026-10-18: clicks on the yellow star did nothing,
// because the star is drawn above the slider and the marker layer passed every
// click through to the empty bar behind it).
@Suite(.serialized) @MainActor struct BookmarkMarkersViewTests {
    private func rig() -> (NSWindow, NSView, BookmarkMarkersView, [Bookmark]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 52), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 52))
        window.contentView = bar
        let markers = BookmarkMarkersView(frame: NSRect(x: 0, y: 0, width: 400, height: 52))
        bar.addSubview(markers)
        let stars = [100.0, 250].map { Bookmark(id: UUID(), fileKey: "k", time: $0, endTime: nil, note: "", createdAt: Date()) }
        markers.duration = 1000
        markers.bookmarks = stars
        window.orderBack(nil)
        return (window, bar, markers, stars)
    }

    /// Where the star is drawn, in the bar's (superview's) coordinates.
    private func starPoint(_ b: Bookmark, _ markers: BookmarkMarkersView, _ bar: NSView) -> NSPoint {
        bar.convert(NSPoint(x: markers.x(for: b)!, y: markers.starCenterY), from: markers)
    }

    @Test("SM1 a click on a star lands on the star layer; anywhere else falls through to the slider")
    func hitTesting() {
        let (window, bar, markers, stars) = rig()
        defer { window.orderOut(nil) }
        #expect(markers.hitTest(starPoint(stars[0], markers, bar)) === markers)
        #expect(markers.hitTest(starPoint(stars[1], markers, bar)) === markers)
        // Same height, between the stars: not a star.
        var gap = starPoint(stars[0], markers, bar); gap.x += 30          // stars sit at x 40 and 100
        #expect(markers.hitTest(gap) == nil)
        // The slider line under a star stays the slider's.
        let slider = bar.convert(NSPoint(x: markers.x(for: stars[0])!, y: markers.bounds.midY + 4), from: markers)
        #expect(markers.hitTest(slider) == nil)
    }

    @Test("SM2 clicking a star reports that star") func clickReports() {
        let (window, bar, markers, stars) = rig()
        defer { window.orderOut(nil) }
        var clicked: [Bookmark] = []
        markers.onClick = { clicked.append($0) }
        for b in [stars[1], stars[0]] {
            let p = bar.convert(starPoint(b, markers, bar), to: nil)
            markers.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       clickCount: 1, pressure: 1)!)
        }
        #expect(clicked.map(\.time) == [250, 100])
    }

    @Test("SM3 when the hovered star goes away (undone with B), its preview is dismissed without moving the mouse")
    func hoveredStarRemoved() {
        let (window, bar, markers, stars) = rig()
        defer { window.orderOut(nil) }
        var hovers: [Bookmark?] = []
        markers.onHover = { b, _ in hovers.append(b) }
        let p = bar.convert(starPoint(stars[0], markers, bar), to: nil)
        markers.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 0, pressure: 0)!)
        #expect(hovers.last??.id == stars[0].id)
        markers.bookmarks = [stars[1]]
        #expect(hovers.count == 2 && hovers.last! == nil)
        markers.bookmarks = [stars[1]]                           // unrelated change: no extra report
        #expect(hovers.count == 2)
    }
}
