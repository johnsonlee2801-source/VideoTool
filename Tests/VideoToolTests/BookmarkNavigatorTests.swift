import Foundation
import Testing
@testable import VideoTool

// User decisions 2026-10-18: jumping to a star lands 2 s before it; B toggles
// (a second B within 1 s / 3 s of a fresh star undoes it).

@Suite struct BookmarkNavigatorTests {
    @Test("N1 jump target is 2 s before the star, never negative") func jumpTarget() {
        #expect(BookmarkNavigator.jumpTarget(60) == 58)
        #expect(BookmarkNavigator.jumpTarget(1.5) == 0)
        #expect(BookmarkNavigator.jumpTarget(0) == 0)
    }

    @Test("N2 next: the first star ahead; after landing on a star, the one after it") func next() {
        let stars = [10.0, 50, 90]
        #expect(BookmarkNavigator.next(after: 0, in: stars) == 10)
        #expect(BookmarkNavigator.next(after: 8, in: stars, landedOn: 10) == 50, "landed 2 s before star 10")
        #expect(BookmarkNavigator.next(after: 30, in: stars) == 50)
        #expect(BookmarkNavigator.next(after: 88, in: stars, landedOn: 90) == nil)
        #expect(BookmarkNavigator.next(after: 95, in: stars) == nil)
        #expect(BookmarkNavigator.next(after: 0, in: []) == nil)
    }

    @Test("N3 previous: back to the star just played past; if just landed on it, the one before") func previous() {
        let stars = [10.0, 50, 90]
        #expect(BookmarkNavigator.previous(before: 70, in: stars) == 50)
        #expect(BookmarkNavigator.previous(before: 48.5, in: stars, landedOn: 50) == 10, "landed on 50 moments ago")
        #expect(BookmarkNavigator.previous(before: 51, in: stars) == 50, "played just past 50")
        #expect(BookmarkNavigator.previous(before: 8.5, in: stars, landedOn: 10) == nil)
        #expect(BookmarkNavigator.previous(before: 200, in: stars) == 90)
    }

    @Test("N10 review: stars in the first 2 s and stars closer than 0.5 s are reachable") func earlyAndClose() {
        #expect(BookmarkNavigator.next(after: 0, in: [2.0]) == 2.0)
        #expect(BookmarkNavigator.next(after: 0, in: [0.5]) == 0.5)
        #expect(BookmarkNavigator.next(after: 8, in: [10, 10.4], landedOn: 10) == 10.4)
        #expect(BookmarkNavigator.previous(before: 8.4, in: [10, 10.4], landedOn: 10.4) == 10)
    }

    @Test("N11 law: chaining next from 0 visits every distinct star once in order; previous reverses it")
    func chainingLaw() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let stars = (0..<Int.random(in: 1...12, using: &rng)).map { _ in (Double.random(in: 0...600, using: &rng) * 10).rounded() / 10 }
            let distinct = Array(Set(stars)).sorted()
            var visited: [Double] = []
            var landed: Double? = nil
            var pos = 0.0
            while let s = BookmarkNavigator.next(after: pos, in: stars, landedOn: landed), visited.count <= distinct.count {
                visited.append(s); landed = s; pos = BookmarkNavigator.jumpTarget(s)
            }
            #expect(visited == distinct, "\(stars)")
            var back: [Double] = []
            while let s = BookmarkNavigator.previous(before: pos, in: stars, landedOn: landed), back.count <= distinct.count {
                back.append(s); landed = s; pos = BookmarkNavigator.jumpTarget(s)
            }
            #expect(back == Array(distinct.reversed().dropFirst()), "\(stars)")
        }
    }

    @Test("N4 next/previous accept unsorted input") func unsorted() {
        #expect(BookmarkNavigator.next(after: 0, in: [90, 10, 50]) == 10)
        #expect(BookmarkNavigator.previous(before: 200, in: [90, 10, 50]) == 90)
    }

    @Test("N5 snap: a click within tolerance lands on the nearest star; otherwise nil") func snap() {
        let stars = [10.0, 12, 50]
        #expect(BookmarkNavigator.snap(10.4, to: stars, tolerance: 0.5) == 10)
        #expect(BookmarkNavigator.snap(11.2, to: stars, tolerance: 1.0) == 12)
        #expect(BookmarkNavigator.snap(11.0, to: stars, tolerance: 1.0) == 10, "tie goes to the earlier star")
        #expect(BookmarkNavigator.snap(30, to: stars, tolerance: 1.0) == nil)
        #expect(BookmarkNavigator.snap(50.5, to: stars, tolerance: 0.5) == 50, "inclusive edge")
    }

    private func star(_ t: Double, createdAgo: Double, now: Date) -> Bookmark {
        Bookmark(id: UUID(), fileKey: "k", time: t, endTime: nil, note: "", createdAt: now.addingTimeInterval(-createdAgo))
    }

    @Test("N6 toggle: a second B near a just-made star undoes it") func toggleUndo() {
        let now = Date(timeIntervalSince1970: 1000)
        let fresh = star(30, createdAgo: 1, now: now)
        #expect(BookmarkNavigator.toggle(at: 30.6, now: now, existing: [fresh]) == .undo(fresh.id))
    }

    @Test("N7 toggle: far away or old stars do not trigger undo") func toggleAdd() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(BookmarkNavigator.toggle(at: 32, now: now, existing: [star(30, createdAgo: 1, now: now)]) == .add)
        #expect(BookmarkNavigator.toggle(at: 30.2, now: now, existing: [star(30, createdAgo: 10, now: now)]) == .add)
        #expect(BookmarkNavigator.toggle(at: 5, now: now, existing: []) == .add)
    }

    @Test("N12 review: at 3× speed a quick double B still undoes (distance scales with speed)") func toggleAtSpeed() {
        let now = Date(timeIntervalSince1970: 1000)
        let fresh = star(30, createdAgo: 0.4, now: now)
        #expect(BookmarkNavigator.toggle(at: 31.2, now: now, existing: [fresh], speed: 3) == .undo(fresh.id))
        #expect(BookmarkNavigator.toggle(at: 31.2, now: now, existing: [fresh], speed: 1) == .add)
    }

    @Test("N8 toggle picks the most recently created qualifying star") func toggleMostRecent() {
        let now = Date(timeIntervalSince1970: 1000)
        let older = star(30, createdAgo: 2.5, now: now), newer = star(30.5, createdAgo: 0.5, now: now)
        #expect(BookmarkNavigator.toggle(at: 30.3, now: now, existing: [older, newer]) == .undo(newer.id))
    }

    @Test("N9 marker x position maps time onto the slider track") func markerX() {
        #expect(BookmarkNavigator.markerX(time: 0, duration: 100, trackMinX: 10, trackWidth: 200) == 10)
        #expect(BookmarkNavigator.markerX(time: 50, duration: 100, trackMinX: 10, trackWidth: 200) == 110)
        #expect(BookmarkNavigator.markerX(time: 150, duration: 100, trackMinX: 10, trackWidth: 200) == 210, "clamped")
        #expect(BookmarkNavigator.markerX(time: 5, duration: 0, trackMinX: 10, trackWidth: 200) == nil)
    }
}
