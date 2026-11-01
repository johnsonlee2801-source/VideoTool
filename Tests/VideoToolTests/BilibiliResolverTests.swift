import Foundation
import Testing
@testable import VideoTool

private final class PendingCatalog: BilibiliCatalogFetching {
    var completions: [(Result<BilibiliCatalog, NetworkVideoFailure>) -> Void] = []
    var cancels = 0
    func fetch(_ video: NetworkVideo, completion: @escaping (Result<BilibiliCatalog, NetworkVideoFailure>) -> Void) { completions.append(completion) }
    func cancel() { cancels += 1 }
}
private final class BiliProcess: NetworkVideoProcessRunning {
    var args: [String] = []
    var completion: ((Result<Data, NetworkVideoFailure>) -> Void)?
    var cancelled = false
    func run(executable: URL, arguments: [String], completion: @escaping (Result<Data, NetworkVideoFailure>) -> Void) { args = arguments; self.completion = completion }
    func cancel() { cancelled = true }
}
@Suite @MainActor struct BilibiliResolverTests {
    @Test("BR1 short/AV identity resolves before extracting one part, without Deno")
    func canonicalAndCancellation() throws {
        let catalog = PendingCatalog(), process = BiliProcess()
        let resolver = NetworkVideoResolver(tools: { (URL(fileURLWithPath: "/tools/yt-dlp"), "") }, makeProcess: { process }, catalog: catalog)
        let request = try NetworkVideo("https://bilibili.com/video/BV1bK411W797?p=2")
        let value = BilibiliCatalog(request: request, parts: [BilibiliPart(page: 1, title: "one"), BilibiliPart(page: 2, title: "two")])
        var results = 0
        resolver.resolve(try NetworkVideo("https://b23.tv/abc")) { _ in results += 1 }
        #expect(process.args.isEmpty)
        catalog.completions[0](.success(value))
        #expect(Array(process.args.suffix(2)) == ["--", request.url.absoluteString])
        #expect(process.args.contains("--no-playlist") && !process.args.contains("--js-runtimes"))
        resolver.cancel()
        process.completion?(.failure(.failed))
        #expect(results == 0 && process.cancelled)
        resolver.resolve(request) { _ in results += 1 }
        resolver.cancel()
        catalog.completions[1](.success(value))
        #expect(results == 0)
    }
    @Test("BR2 metadata failure never replaces current playback or starts extraction")
    func metadataFailure() throws {
        let catalog = PendingCatalog()
        let resolver = NetworkVideoResolver(tools: { (URL(fileURLWithPath: "/tools/yt-dlp"), "") }, makeProcess: { Issue.record("must not start"); return BiliProcess() }, catalog: catalog)
        var result: NetworkVideoFailure?
        resolver.resolve(try NetworkVideo("https://bilibili.com/video/BV1bK411W797")) { if case .failure(let e) = $0 { result = e } }
        catalog.completions[0](.failure(.timeout))
        #expect(result == .timeout)
    }
}
