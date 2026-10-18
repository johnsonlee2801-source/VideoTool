import Testing
@testable import VideoTool

@Suite struct ScrubPolicyTests {
    private let noSnap: (Double, Double) -> Double = { v, _ in v }

    @Test("SP1 dragging scrubs with fast keyframe seeks") func drag() {
        let d = ScrubPolicy.decide(isDrag: true, value: 42, duration: 100, trackWidth: 500, snapRadius: 6, snap: noSnap)
        #expect(d == .init(isScrubbing: true, seek: .keyframe(42)))
    }

    @Test("SP2 a click or release ends scrubbing with one exact seek") func click() {
        let d = ScrubPolicy.decide(isDrag: false, value: 42, duration: 100, trackWidth: 500, snapRadius: 6, snap: noSnap)
        #expect(d == .init(isScrubbing: false, seek: .exact(42)))
    }

    @Test("SP3 the snap tolerance converts the pixel radius using the track width") func tolerance() {
        var seen = -1.0
        _ = ScrubPolicy.decide(isDrag: false, value: 10, duration: 1000, trackWidth: 500, snapRadius: 6) { v, t in seen = t; return v }
        #expect(seen == 12, "6 pt on a 500 pt track of a 1000 s video = 12 s")
    }

    @Test("SP4 a click near a star seeks where the snap rule says (2 s before the star)") func snaps() {
        let d = ScrubPolicy.decide(isDrag: false, value: 101, duration: 600, trackWidth: 600, snapRadius: 6) { v, t in
            BookmarkNavigator.snap(v, to: [100], tolerance: t).map(BookmarkNavigator.jumpTarget) ?? v
        }
        #expect(d.seek == .exact(98))
    }

    @Test("SP5 values outside the video are clamped; zero width never divides by zero") func edges() {
        #expect(ScrubPolicy.decide(isDrag: true, value: -5, duration: 100, trackWidth: 500, snapRadius: 6, snap: noSnap).seek == .keyframe(0))
        #expect(ScrubPolicy.decide(isDrag: false, value: 150, duration: 100, trackWidth: 0, snapRadius: 6, snap: noSnap).seek == .exact(100))
    }
}
