import Foundation
import Testing
@testable import VideoTool

private final class PendingYouTubeProcess: NetworkVideoProcessRunning {
    var args: [String] = []
    var completion: ((Result<Data, NetworkVideoFailure>) -> Void)?
    var cancelled = false
    func run(executable: URL, arguments: [String], completion: @escaping (Result<Data, NetworkVideoFailure>) -> Void) {
        args = arguments; self.completion = completion
    }
    func cancel() { cancelled = true }
}

@Suite @MainActor struct YouTubeResolverTests {
    @Test("YR1 arguments isolate settings and only the canonical URL reaches the process")
    func invocation() throws {
        let args = NetworkVideoResolver.arguments(for: try NetworkVideo("https://youtu.be/BaW_jenozKc?list=abc&t=1"), deno: "/tools/deno")
        for flag in ["--ignore-config", "--no-cache-dir", "--no-plugin-dirs", "--no-remote-components", "--no-playlist", "--skip-download"] { #expect(args.contains(flag)) }
        #expect(Array(args.suffix(2)) == ["--", "https://www.youtube.com/watch?v=BaW_jenozKc"])
        #expect(!args.contains(where: { $0.contains("cookies") || $0.contains("exec") }))
        let formatIndex = try #require(args.firstIndex(of: "--format"))
        #expect(args[formatIndex + 1] == "bestvideo[height<=1080]+bestaudio/best[height<=1080]")
    }

    @Test("YR2 cancelled and replaced requests cannot deliver a late completion")
    func staleCompletion() throws {
        var processes: [PendingYouTubeProcess] = []
        let resolver = NetworkVideoResolver(tools: { (URL(fileURLWithPath: "/tools/yt-dlp"), "/tools/deno") }, makeProcess: {
            let p = PendingYouTubeProcess(); processes.append(p); return p
        })
        var calls = 0
        let request = try NetworkVideo("https://youtu.be/BaW_jenozKc")
        resolver.resolve(request) { _ in calls += 1 }
        resolver.resolve(request) { _ in calls += 1 }
        #expect(processes[0].cancelled)
        processes[0].completion?(.failure(.failed))
        #expect(calls == 0)
        resolver.cancel()
        processes[1].completion?(.failure(.failed))
        #expect(calls == 0 && processes[1].cancelled)
    }

    @Test("YR3 absent dependencies fail clearly without starting a process")
    func missingTools() throws {
        let resolver = NetworkVideoResolver(tools: { nil }, makeProcess: { Issue.record("must not run"); return PendingYouTubeProcess() })
        var failure: NetworkVideoFailure?
        resolver.resolve(try NetworkVideo("https://youtu.be/BaW_jenozKc")) { if case .failure(let e) = $0 { failure = e } }
        #expect(failure == .missingTools)
    }

    @Test("YR4 real subprocess drains output and times out without blocking the main thread")
    func processBounds() async throws {
        let runner = NetworkVideoProcess(timeout: 0.2, maxBytes: 64)
        var result: Result<Data, NetworkVideoFailure>?
        runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]) { result = $0 }
        let deadline = Date().addingTimeInterval(3)
        while result == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .failure(.timeout)? = result else { Issue.record("expected bounded timeout"); return }
        let echo = NetworkVideoProcess(timeout: 2, maxBytes: 4)
        result = nil
        echo.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["123456789"]) { result = $0 }
        let end = Date().addingTimeInterval(3)
        while result == nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        guard case .failure(.invalidResponse)? = result else { Issue.record("oversized output accepted"); return }
    }
}

@Suite struct NetworkRuntimeOrderTests {
    @Test("NR1 explicit YouTube JS runtime must follow clearing defaults")
    func order() throws {
        let args = NetworkVideoResolver.arguments(for: try NetworkVideo("https://youtu.be/BaW_jenozKc"), deno: "/tools/deno")
        #expect(try #require(args.firstIndex(of: "--no-js-runtimes")) < #require(args.firstIndex(of: "--js-runtimes")))
        let bili = NetworkVideoResolver.arguments(for: try NetworkVideo("https://bilibili.com/video/BV1bK411W797?p=2"), deno: "")
        #expect(!bili.contains("--js-runtimes"))
    }
}
