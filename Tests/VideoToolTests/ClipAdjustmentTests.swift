import Foundation
import Testing
@testable import VideoTool

@Suite struct ClipAdjustmentTests {
    @Test("CA1 adjusting either end clamps to duration and preserves a valid minimum selection")
    func bounds() {
        var selection = ClipSelection()
        _ = selection.mark(8); _ = selection.mark(2)
        selection.adjust(.start, to: 20, duration: 30)
        #expect(selection.range == ClipRange(start: 7.5, end: 8))
        selection.adjust(.end, to: 0, duration: 30)
        #expect(selection.range == ClipRange(start: 7.5, end: 8))
        selection.adjust(.start, to: -20, duration: 30)
        selection.adjust(.end, to: 100, duration: 30)
        #expect(selection.range == ClipRange(start: 0, end: 30))
        selection.adjust(.end, to: .nan, duration: 30)
        #expect(selection.range == ClipRange(start: 0, end: 30))
    }
    @Test("CA2 local zoom maps pointer positions within a bounded detail window")
    func zoom() {
        let window = ClipZoomWindow(center: 10, duration: 20)
        #expect(window.lower < 10 && window.upper > 10 && window.upper - window.lower <= 6)
        #expect(window.time(fraction: -1) == window.lower)
        #expect(window.time(fraction: 2) == window.upper)
        #expect(ClipAdjustment.text(59.9997) == "1:00.000")
        #expect(ClipAdjustment.step(fps: nil) == 0.01)
        #expect(ClipAdjustment.step(fps: 24) == 1.0 / 24)
        let edge = ClipZoomWindow(center: 0, duration: 1)
        #expect(edge.lower == 0 && edge.upper <= 1)
    }
}
