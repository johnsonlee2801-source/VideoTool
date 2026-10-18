import AppKit
import Testing
import UniformTypeIdentifiers
@testable import VideoTool

private struct Boom: Error {}

@Suite struct DefaultAppRegistrarTests {
    @Test("D1 completions arriving concurrently are all counted (no lost or racing appends)")
    func concurrentCompletions() async {
        let types = MediaTypes.utTypes
        for _ in 0..<30 {
            let summary: DefaultAppRegistrar.Summary = await withCheckedContinuation { cont in
                DefaultAppRegistrar.makeDefault(
                    types: types, appURL: URL(fileURLWithPath: "/Applications/VideoTool.app"),
                    setter: { _, type, done in
                        DispatchQueue.global().async {
                            done(type.identifier.hashValue % 2 == 0 ? Boom() : nil)
                        }
                    },
                    completion: { cont.resume(returning: $0) })
            }
            let expectedFailures = types.filter { $0.identifier.hashValue % 2 == 0 }.count
            #expect(summary.total == types.count)
            #expect(summary.failures.count == expectedFailures)
        }
    }

    @Test("D2 completion runs on the main thread") @MainActor
    func completionOnMain() async {
        let onMain: Bool = await withCheckedContinuation { cont in
            DefaultAppRegistrar.makeDefault(types: [.movie], appURL: URL(fileURLWithPath: "/x.app"),
                                            setter: { _, _, done in DispatchQueue.global().async { done(nil) } },
                                            completion: { _ in cont.resume(returning: Thread.isMainThread) })
        }
        #expect(onMain)
    }

    @Test("D3 summary message: all ok vs partial failure") func message() {
        #expect(DefaultAppRegistrar.Summary(total: 3, failures: []).message.contains("3"))
        let partial = DefaultAppRegistrar.Summary(total: 3, failures: ["public.movie: x"])
        #expect(partial.message.contains("失败 1"))
    }

    @Test("D4 requests go one at a time: the next starts only after the previous completes") func sequential() async {
        var inFlight = 0, maxInFlight = 0
        let lock = NSLock()
        let _: DefaultAppRegistrar.Summary = await withCheckedContinuation { cont in
            DefaultAppRegistrar.makeDefault(types: MediaTypes.videoUTTypes, appURL: URL(fileURLWithPath: "/x.app"),
                                            setter: { _, _, done in
                                                lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
                                                DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) {
                                                    lock.lock(); inFlight -= 1; lock.unlock()
                                                    done(nil)
                                                }
                                            }, completion: { cont.resume(returning: $0) })
        }
        #expect(maxInFlight == 1)
    }

    @Test("D5 the most common formats are asked first") func order() {
        let first = MediaTypes.videoUTTypes.prefix(3).map(\.identifier)
        #expect(first == ["public.mpeg-4", "com.apple.quicktime-movie", "org.matroska.mkv"])
    }
}
