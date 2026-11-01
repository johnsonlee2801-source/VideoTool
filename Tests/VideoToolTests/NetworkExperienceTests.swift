import AppKit
import Testing
@testable import VideoTool

@Suite @MainActor struct NetworkExperienceTests {
    @Test("NE1 URL pasteboard accepts supported web links without treating arbitrary text as media")
    func input() throws {
        let board = NSPasteboard(name: .init("network-input-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("https://b23.tv/BV1bK411W797", forType: .string)
        #expect(PlayerView.networkURL(on: board)?.host == "b23.tv")
        board.clearContents(); board.setString("https://evil.test/video", forType: .string)
        #expect(PlayerView.networkURL(on: board) == nil)
    }
    @Test("NE2 diagnostics produce fixed safe error categories")
    func errors() {
        #expect(NetworkVideoFailure.classify("ERROR: Sign in to confirm your age") == .restricted)
        #expect(NetworkVideoFailure.classify("ERROR: HTTP Error 403: Forbidden") == .restricted)
        #expect(NetworkVideoFailure.classify("ERROR: Unable to download webpage: timed out") == .network)
        #expect(NetworkVideoFailure.classify("ERROR: Error solving n challenge") == .componentUpdate)
    }
    @Test("NE7 Bilibili login denial produces an actionable safe category")
    func biliDenial() throws {
        let request = try NetworkVideo("https://bilibili.com/video/BV1bK411W797")
        do {
            _ = try BilibiliCatalog.decode(Data(#"{"code":-101}"#.utf8), request: request)
            Issue.record("expected restricted failure")
        } catch { #expect(error as? NetworkVideoFailure == .restricted) }
    }
    @Test("NE3 observed buffering and decoded quality describe the active stream")
    func progress() {
        var state = PlayerState()
        let changedBuffer = state.apply(.pausedForCache, .flag(true))
        #expect(changedBuffer)
        #expect(state.isBuffering)
        let changedHeight = state.apply(.videoHeight, .double(720))
        #expect(changedHeight)
        #expect(state.videoHeight == 720)
    }
}

private final class ExperienceResolver: NetworkVideoResolving {
    var requests: [NetworkVideo] = []
    var completion: ((Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void)?
    func resolve(_ video: NetworkVideo, completion: @escaping (Result<ResolvedNetworkVideo, NetworkVideoFailure>) -> Void) { requests.append(video); self.completion = completion }
    func cancel() {}
}
@Suite(.serialized) @MainActor struct NetworkInputGlueTests {
    @Test("NE4 Cmd-V opens a supported link and leaves text editing alone")
    func paste() throws {
        let w = PlayerWindowController(), resolver = ExperienceResolver()
        defer { w.shutdown() }
        w.networkResolverFactory = { resolver }
        let board = NSPasteboard(name: .init("network-cmd-v-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        w.pasteboard = board
        board.setString("https://youtu.be/M7lc1UVf-VE?t=12", forType: .string)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 1, windowNumber: w.window!.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        #expect(w.handleKeyDown(event) == nil)
        #expect(resolver.requests.count == 1 && resolver.requests.first?.start == 12)
        let editor = NSTextView(frame: .zero)
        w.window?.contentView?.addSubview(editor); w.window?.makeFirstResponder(editor)
        #expect(w.handleKeyDown(event) != nil)
        #expect(resolver.requests.count == 1)
    }
    @Test("NE5 stderr is drained and only a categorized failure is returned")
    func subprocessDiagnostics() async throws {
        let process = NetworkVideoProcess(timeout: 3)
        var result: Result<Data, NetworkVideoFailure>?
        process.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 2000 ]; do echo diagnostic-line-ignored >&2; i=$((i+1)); done; echo 'ERROR: HTTP Error 403: Forbidden' >&2; exit 1"]) { result = $0 }
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .failure(.restricted)? = result else { Issue.record("expected safe restricted category"); return }
    }
}
