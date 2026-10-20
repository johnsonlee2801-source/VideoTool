import AppKit
import Testing
@testable import VideoTool

// C marks the start and the end of a clip; a bar then offers GIF, video, copy and a
// looping preview (2026-10-20: "B is for going back, C is for cutting").
// ⌘C copies the picture on screen.

private final class Marker {}
private func fixture(_ name: String, _ ext: String) -> URL {
    URL(fileURLWithPath: Bundle(for: Marker.self).path(forResource: name, ofType: ext)!)
}
@MainActor
private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
private func tempDir(_ tag: String) throws -> URL {
    let d = TestTemp.directory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct ClipSelectionTests {
    @Test("CS1 the first C sets the start, the second the end; either order works")
    func marks() {
        var s = ClipSelection()
        #expect(s.mark(65) == .started(65))
        #expect(s.range == nil && s.start == 65)
        #expect(s.mark(125) == .completed(ClipRange(start: 65, end: 125)))
        #expect(s.range == ClipRange(start: 65, end: 125))
        var back = ClipSelection()
        _ = back.mark(125)
        #expect(back.mark(65) == .completed(ClipRange(start: 65, end: 125)), "end before start: swapped")
    }

    @Test("CS2 a second C at (almost) the same moment is not a clip; a third C starts over; clear forgets")
    func edges() {
        var s = ClipSelection()
        _ = s.mark(10)
        #expect(s.mark(10.2) == .tooShort)
        #expect(s.start == 10 && s.range == nil)
        _ = s.mark(20)
        #expect(s.mark(40) == .started(40), "a new clip after a finished one")
        #expect(s.range == nil)
        s.clear()
        #expect(s == ClipSelection())
    }

    @Test("CS3 C is the clip key; ⌘C is left to the menu (copy)")
    func key() {
        #expect(KeyCommandMap.command(for: KeyInput(key: "c")) == .markClip)
        #expect(KeyCommandMap.command(for: KeyInput(key: "c", command: true)) == nil)
    }

    @Test("CS4 file names say where the clip is, and never replace an earlier one")
    func names() throws {
        let dir = try tempDir("cn")
        let first = ClipNaming.freeURL(in: dir, video: "Show S01E02.mkv", range: ClipRange(start: 65, end: 125.4), ext: "gif")
        #expect(first.lastPathComponent == "Show S01E02 1-05–2-06.gif")
        try Data().write(to: first)
        #expect(ClipNaming.freeURL(in: dir, video: "Show S01E02.mkv", range: ClipRange(start: 65, end: 125.4), ext: "gif")
            .lastPathComponent == "Show S01E02 1-05–2-06 (2).gif")
    }
}

@Suite @MainActor struct ClipBarTests {
    @Test("CB1 the bar shows the stretch and its length; GIF is offered only up to 20 s")
    func gifLimit() {
        let bar = ClipBar()
        bar.show(ClipRange(start: 65, end: 75))
        #expect(bar.textForTesting.contains("1:05") && bar.textForTesting.contains("1:15") && bar.textForTesting.contains("10"))
        #expect(bar.isEnabled(.gif))
        bar.show(ClipRange(start: 65, end: 125))
        #expect(!bar.isEnabled(.gif), "60 s: too long for a GIF")
        #expect(bar.isEnabled(.video) && bar.isEnabled(.copy))
    }

    @Test("CB3 Copy says what it will copy, and a long clip says why there is no GIF")
    func copySaysWhat() {
        let bar = ClipBar()
        bar.show(ClipRange(start: 65, end: 75))
        #expect(bar.title(of: .copy) == L("拷贝 GIF"))
        #expect(!bar.textForTesting.contains(L("超过 %@ 秒，只能导出视频", "20")))
        bar.show(ClipRange(start: 65, end: 125))
        #expect(bar.title(of: .copy) == L("拷贝视频"))
        #expect(bar.textForTesting.contains(L("超过 %@ 秒，只能导出视频", "20")))
    }

    @Test("CB2 each button reports its action")
    func actions() {
        let bar = ClipBar()
        var log: [ClipBar.Action] = []
        bar.onAction = { log.append($0) }
        bar.show(ClipRange(start: 1, end: 5))
        for a in [ClipBar.Action.gif, .video, .copy, .loop, .close] { bar.press(a) }
        #expect(log == [.gif, .video, .copy, .loop, .close])
    }
}

@Suite(.serialized) @MainActor struct ClipSelectionPlayerTests {
    private func player() async throws -> (PlayerWindowController, MPVEngine, URL, URL) {
        let dir = try tempDir("csp")
        let video = dir.appendingPathComponent("Talk.mp4")
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: video)
        let out = try tempDir("csp-out")
        let w = PlayerWindowController()
        w.clipOutputDirectory = out
        w.open(video)
        let engine = try #require(w.engine)
        #expect(await waitUntil { w.loadedPath == video.path })
        engine.setPaused(true)
        return (w, engine, video, out)
    }

    private func markClip(_ w: PlayerWindowController, _ engine: MPVEngine, at t: Double) async {
        engine.seek(to: t)
        _ = await waitUntil { abs(engine.state.timePos - t) < 0.2 }
        w.perform(.markClip)
    }

    @Test("CP1 C at 2 s and C at 4 s: the bar appears; GIF saves a file there and shows it in Finder")
    func quickGIF() async throws {
        let (w, engine, _, out) = try await player()
        defer { w.shutdown() }
        var revealed: [URL] = []
        w.revealExported = { revealed = $0 }
        await markClip(w, engine, at: 2)
        #expect(w.clipBar.isHidden, "one end only")
        #expect(w.playerView?.hud.text == L("片段从 %@ 开始，再按 C 标记结尾", "0:02"))
        await markClip(w, engine, at: 4)
        #expect(!w.clipBar.isHidden)
        #expect(w.markersForTesting.clipRange != nil)
        w.clipBar.press(.gif)
        #expect(await waitUntil(20) { !revealed.isEmpty })
        #expect(revealed.first?.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
        #expect(revealed.first?.lastPathComponent.hasPrefix("Talk 0-02–0-04") == true)
        #expect(revealed.first?.pathExtension == "gif")
    }

    @Test("CP2 Copy puts the exported clip on the clipboard, ready to paste into a chat")
    func copyClip() async throws {
        let (w, engine, _, _) = try await player()
        defer { w.shutdown() }
        let board = NSPasteboard(name: .init("videotool-test-\(UUID().uuidString)"))
        w.pasteboard = board
        w.revealExported = { _ in Issue.record("copy does not open Finder") }
        await markClip(w, engine, at: 1)
        await markClip(w, engine, at: 2)
        w.clipBar.press(.copy)
        #expect(await waitUntil(20) { (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.isEmpty == false })
        let url = try #require((board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(w.playerView?.hud.text == L("已拷贝，可以直接粘贴"))
    }

    @Test("CP3 Loop preview plays just the clip, round and round; again stops it")
    func loopPreview() async throws {
        let (w, engine, _, _) = try await player()
        defer { w.shutdown() }
        await markClip(w, engine, at: 3)
        await markClip(w, engine, at: 6)
        w.clipBar.press(.loop)
        #expect(await waitUntil { engine.property("ab-loop-a") == "3.000000" && engine.property("ab-loop-b") == "6.000000" },
                "a=\(engine.property("ab-loop-a") ?? "nil") b=\(engine.property("ab-loop-b") ?? "nil")")
        #expect(await waitUntil { !engine.state.isPaused }, "the preview plays")
        w.clipBar.press(.loop)
        #expect(await waitUntil { engine.property("ab-loop-a") == "no" })
    }

    @Test("CP4 × or another file clears the clip (and its loop)")
    func clears() async throws {
        let (w, engine, _, _) = try await player()
        defer { w.shutdown() }
        await markClip(w, engine, at: 3)
        await markClip(w, engine, at: 6)
        w.clipBar.press(.loop)
        w.clipBar.press(.close)
        #expect(w.clipBar.isHidden && w.markersForTesting.clipRange == nil && w.markersForTesting.clipStart == nil)
        #expect(await waitUntil { engine.property("ab-loop-a") == "no" })
        await markClip(w, engine, at: 3)
        await markClip(w, engine, at: 6)
        let other = try tempDir("csp2").appendingPathComponent("Other.mp4")
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: other)
        w.open(other)
        #expect(w.clipBar.isHidden && w.markersForTesting.clipRange == nil)
    }

    @Test("CP5 ⌘C copies the picture on screen")
    func copyFrame() async throws {
        let (w, engine, _, _) = try await player()
        defer { w.shutdown() }
        let board = NSPasteboard(name: .init("videotool-test-\(UUID().uuidString)"))
        w.pasteboard = board
        engine.seek(to: 5)
        _ = await waitUntil { abs(engine.state.timePos - 5) < 0.2 }
        w.copy(nil)
        #expect(await waitUntil(15) { board.readObjects(forClasses: [NSImage.self])?.isEmpty == false })
        let image = try #require(board.readObjects(forClasses: [NSImage.self])?.first as? NSImage)
        #expect(image.size.width >= 600, "full size, not a thumbnail: \(image.size)")
        #expect(w.playerView?.hud.text == L("已拷贝画面"))
    }

    @Test("CP6 the Edit menu exists: ⌘C, ⌘V and ⌘A work in text fields (star notes)")
    func editMenu() throws {
        let menu = try #require(NSApp.mainMenu)
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == L("编辑") })
        let shortcuts = edit.items.filter { !$0.isSeparatorItem }.map { "\($0.keyEquivalent)" }
        #expect(["x", "c", "v", "a"].allSatisfy(shortcuts.contains), "\(shortcuts)")
        #expect(edit.items.contains { $0.action == #selector(NSText.copy(_:)) })
    }
}
