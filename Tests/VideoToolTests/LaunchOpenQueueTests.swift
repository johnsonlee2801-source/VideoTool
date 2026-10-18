import Foundation
import Testing
@testable import VideoTool

@Suite struct LaunchOpenQueueTests {
    private let a = URL(fileURLWithPath: "/m/a.mkv")
    private let b = URL(fileURLWithPath: "/m/b.mp4")

    @Test("L1 files received during launch are queued, then opened exactly once") func queuedDuringLaunch() {
        var q = LaunchOpenQueue()
        #expect(q.receive([a]) == nil)
        #expect(q.finishLaunching(commandLine: [a]) == a, "AppKit and argv both delivered it: open once")
        #expect(q.receive([]) == nil)
    }
    @Test("L2 after launch, received files open immediately") func afterLaunch() {
        var q = LaunchOpenQueue()
        _ = q.finishLaunching(commandLine: [])
        #expect(q.receive([b]) == b)
    }
    @Test("L3 non-media arguments are ignored (Xcode passes -NSDocumentRevisionsDebugMode etc.)") func filtersNonMedia() {
        var q = LaunchOpenQueue()
        #expect(q.finishLaunching(commandLine: [URL(fileURLWithPath: "/tmp/YES"), URL(fileURLWithPath: "/m/notes.txt")]) == nil)
        #expect(q.receive([URL(fileURLWithPath: "/m/readme.md"), a]) == a)
    }
    @Test("L4 launch with nothing to open returns nil") func emptyLaunch() {
        var q = LaunchOpenQueue()
        #expect(q.finishLaunching(commandLine: []) == nil)
        #expect(q.hasFinishedLaunching)
    }
}
