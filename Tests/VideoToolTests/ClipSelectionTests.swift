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
        #expect(await waitUntil { abs(engine.state.timePos - t) < 0.05 }, "seek to \(t): at \(engine.state.timePos)")
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

// Audit 2026-10-20 (clip feature) fixes.

/// One ASS cue painting the bottom third red from `from` to `to` seconds.
private func redCue(from: Double, to: Double) throws -> URL {
    let url = TestTemp.directory.appendingPathComponent("redcue-\(UUID().uuidString).ass")
    func t(_ s: Double) -> String { String(format: "0:00:%05.2f", s) }
    try """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,40,&H000000FF,&H000000FF,&H000000FF,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,\(t(from)),\(t(to)),Default,,0,0,0,,{\\pos(0,240)\\p1}m 0 0 l 640 0 640 120 0 120{\\p0}
    """.write(to: url, atomically: true, encoding: .utf8)
    return url
}
private func bottomIsRed(_ jpeg: URL) throws -> Bool {
    let image = try #require(NSImage(contentsOf: jpeg)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -0.5 * Double(image.width), y: -0.15 * Double(image.height), width: Double(image.width), height: Double(image.height)))
    return px[0] > 170 && px[1] < 90 && px[2] < 90
}

struct ClipAuditFixTests {
    @Test("CF1 subtitles shifted with Z/X are shifted the same in copies and clips")
    func subtitleDelay() throws {
        let ass = try redCue(from: 0, to: 1)
        let src = fixture("testsrc-20s", "mp4").path
        let plain = TestTemp.directory.appendingPathComponent("d0-\(UUID().uuidString).jpg")
        let late = TestTemp.directory.appendingPathComponent("d1-\(UUID().uuidString).jpg")
        #expect(MPVFrameGrabber.grab(source: src, start: "1.5", thumbnailTo: plain, subtitles: ass.path).failure == nil)
        #expect(MPVFrameGrabber.grab(source: src, start: "1.5", thumbnailTo: late, subtitles: ass.path, subtitleDelay: 1).failure == nil)
        #expect(try !bottomIsRed(plain), "the cue ended at 1 s")
        #expect(try bottomIsRed(late), "1 s later: shown 1–2 s")
    }

    @Test("CF2 very long video names still make valid file names, time stamps and extension kept")
    func longNames() throws {
        let dir = try tempDir("long")
        for stem in [String(repeating: "a", count: 250), String(repeating: "长", count: 120)] {
            let url = ClipNaming.freeURL(in: dir, video: stem + ".mp4", range: ClipRange(start: 65, end: 125), ext: "gif")
            let name = url.lastPathComponent
            #expect(name.utf8.count <= ClipNaming.maxNameBytes, "\(name.utf8.count) bytes")
            #expect(name.hasSuffix(" 1-05–2-05.gif"))
            try Data().write(to: url)                     // and it can actually be created
            let next = ClipNaming.freeURL(in: dir, video: stem + ".mp4", range: ClipRange(start: 65, end: 125), ext: "gif")
            #expect(next.lastPathComponent.utf8.count <= ClipNaming.maxNameBytes && next != url)
        }
    }

    @Test("CF3 a quick export never replaces a file, even one that appeared while exporting")
    func noReplace() async throws {
        let dir = try tempDir("norep")
        let target = dir.appendingPathComponent("clip.gif")
        try Data("someone else's".utf8).write(to: target)        // appeared after the name was chosen
        let made = try await ClipExporter.export(source: fixture("testsrc-20s", "mp4"), range: ClipRange(start: 1, end: 1.5),
                                                 format: .gif, to: target, replaceExisting: false)
        #expect(made.first?.lastPathComponent == "clip (2).gif")
        #expect(try Data(contentsOf: target) == Data("someone else's".utf8))
    }

    @Test("CF4 copied clips go to VideoTool's own folder, and day-old ones are cleaned up")
    func copyFolder() throws {
        let dir = try tempDir("copies")
        let old = dir.appendingPathComponent("old.gif"), fresh = dir.appendingPathComponent("fresh.gif")
        try Data().write(to: old); try Data().write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: old.path)
        ClipNaming.cleanUp(dir, olderThan: 86400)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(ClipNaming.copyDirectory.path.hasPrefix(AppData.directory.path), "not the shared temp folder")
    }
}

@Suite(.serialized) @MainActor struct ClipAuditPlayerTests {
    private func player(_ name: String = "Talk.mp4") async throws -> (PlayerWindowController, MPVEngine, URL) {
        let dir = try tempDir("cap")
        let video = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: video)
        let w = PlayerWindowController()
        w.clipOutputDirectory = try tempDir("cap-out")
        w.open(video)
        let engine = try #require(w.engine)
        #expect(await waitUntil { w.loadedPath == video.path })
        engine.setPaused(true)
        return (w, engine, video)
    }
    private func at(_ engine: MPVEngine, _ t: Double) async {
        engine.seek(to: t)
        #expect(await waitUntil { abs(engine.state.timePos - t) < 0.05 }, "seek to \(t): at \(engine.state.timePos)")
    }
    private func key(_ w: PlayerWindowController, _ c: String, code: UInt16, repeat r: Bool) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.window?.windowNumber ?? 0,
                         context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: r, keyCode: code)!
    }

    @Test("CA1 holding C marks one end only (the repeats are ignored)")
    func heldC() async throws {
        let (w, engine, _) = try await player()
        defer { w.shutdown() }
        await at(engine, 2)
        _ = w.handleKeyDown(key(w, "c", code: 8, repeat: false))
        await at(engine, 4)
        for _ in 0..<5 { _ = w.handleKeyDown(key(w, "c", code: 8, repeat: true)) }
        #expect(w.markersForTesting.clipStart == 2 && w.clipBar.isHidden)
    }

    @Test("CA2 with subtitles switched off, copies and clips carry none")
    func subtitlesOff() async throws {
        let (w, engine, video) = try await player("Off.mp4")
        defer { w.shutdown() }
        let prefs = AISubtitlePreferences()
        prefs.source = "en-US"; prefs.target = nil
        let srt = SubtitleCache.url(forVideo: video.path, source: "en-US", target: nil)
        try FileManager.default.createDirectory(at: srt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SRT.document([SubtitleCue(start: 0, end: 30, text: "Hi.")]).write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }
        w.open(video)
        #expect(await waitUntil { w.loadedPath == video.path && w.clipSubtitleFile != nil }, "AI subtitles on screen")
        w.perform(.cycleSubtitle)                                 // S: subtitles off
        #expect(await waitUntil { engine.property("sid") == "no" })
        #expect(w.clipSubtitleFile == nil)
        _ = engine
    }

    @Test("CA3 a slow clip copy does not replace what was copied meanwhile")
    func clipboardRace() async throws {
        let (w, engine, _) = try await player()
        defer { w.shutdown() }
        let board = NSPasteboard(name: .init("videotool-test-\(UUID().uuidString)"))
        w.pasteboard = board
        await at(engine, 1); w.perform(.markClip)
        await at(engine, 3); w.perform(.markClip)
        w.clipBar.press(.copy)
        board.clearContents(); board.setString("my note", forType: .string)    // copied something else meanwhile
        #expect(await waitUntil(20) { !w.isExportingClip })
        #expect(board.string(forType: .string) == "my note")
        #expect(w.playerView?.hud.text == L("片段已存好，剪贴板里的新内容没有被覆盖"))
    }

    @Test("CA4 pressing ⌘C repeatedly decodes one frame at a time, and the last press wins")
    func frameCopyCoalesced() async throws {
        let (w, engine, _) = try await player()
        defer { w.shutdown() }
        let board = NSPasteboard(name: .init("videotool-test-\(UUID().uuidString)"))
        w.pasteboard = board
        final class Probe: @unchecked Sendable { let lock = NSLock(); var running = 0, most = 0, times: [Double] = [] }
        let probe = Probe()
        w.frameGrab = { _, time, _, _ in
            probe.lock.lock(); probe.running += 1; probe.most = max(probe.most, probe.running); probe.times.append(time); probe.lock.unlock()
            Thread.sleep(forTimeInterval: 0.3)
            probe.lock.lock(); probe.running -= 1; probe.lock.unlock()
            return NSImage(size: NSSize(width: 8, height: 8))
        }
        for t in [2.0, 3, 4, 5] { await at(engine, t); w.copy(nil) }
        #expect(await waitUntil(10) { w.playerView?.hud.text == L("已拷贝画面") && probe.running == 0 })
        probe.lock.lock(); let most = probe.most, times = probe.times; probe.lock.unlock()
        #expect(most == 1, "at most one decoder")
        #expect(times.last == 5, "the latest press is what ends up copied: \(times)")
        #expect(times.count < 4, "superseded presses were skipped: \(times)")
    }

    @Test("CA5 opening another file while the clip loops ends the loop")
    func loopEndsOnOpen() async throws {
        let (w, engine, _) = try await player()
        defer { w.shutdown() }
        await at(engine, 3); w.perform(.markClip)
        await at(engine, 6); w.perform(.markClip)
        w.clipBar.press(.loop)
        #expect(await waitUntil { engine.property("ab-loop-a") == "3.000000" })
        let other = try tempDir("cap2").appendingPathComponent("Other.mp4")
        try FileManager.default.copyItem(at: fixture("testsrc-20s", "mp4"), to: other)
        w.open(other)
        #expect(await waitUntil { w.loadedPath == other.path })
        #expect(await waitUntil { engine.property("ab-loop-a") == "no" && engine.property("ab-loop-b") == "no" })
    }
}
