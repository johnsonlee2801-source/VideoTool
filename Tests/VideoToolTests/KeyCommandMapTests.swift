import Testing
@testable import VideoTool

@Suite struct KeyCommandMapTests {
    private func cmd(_ key: String, shift: Bool = false, command: Bool = false, option: Bool = false, control: Bool = false) -> PlayerCommand? {
        KeyCommandMap.command(for: KeyInput(key: key, shift: shift, command: command, option: option, control: control))
    }

    @Test("space toggles pause") func space() { #expect(cmd(KeyInput.space) == .togglePause) }
    @Test("arrows seek 5 s, shift-arrows 30 s") func arrows() {
        #expect(cmd(KeyInput.left) == .seek(-5))
        #expect(cmd(KeyInput.right) == .seek(5))
        #expect(cmd(KeyInput.left, shift: true) == .seek(-30))
        #expect(cmd(KeyInput.right, shift: true) == .seek(30))
    }
    @Test("up/down change volume by 5") func volume() {
        #expect(cmd(KeyInput.up) == .volume(5))
        #expect(cmd(KeyInput.down) == .volume(-5))
    }
    @Test("letters: f fullscreen, m mute, s subtitle, a audio") func letters() {
        #expect(cmd("f") == .toggleFullscreen)
        #expect(cmd("m") == .toggleMute)
        #expect(cmd("s") == .cycleSubtitle)
        #expect(cmd("a") == .cycleAudio)
    }
    @Test("brackets step speed, delete resets it") func speed() {
        #expect(cmd("[") == .speedDelta(-0.1))
        #expect(cmd("]") == .speedDelta(0.1))
        #expect(cmd(KeyInput.delete) == .resetSpeed)
    }
    @Test("command / option / control chords are left to the menu bar") func chords() {
        #expect(cmd("f", command: true) == nil)
        #expect(cmd(KeyInput.space, option: true) == nil)
        #expect(cmd("m", control: true) == nil)
    }
    @Test("unknown keys map to nothing") func unknown() {
        #expect(cmd("q") == nil)
        #expect(cmd(KeyInput.escape) == nil)
        #expect(cmd("") == nil)
    }

    @Test("B stars the current moment; ⌥← / ⌥→ jump between stars") func bookmarkKeys() {
        #expect(cmd("b") == .toggleBookmark)
        #expect(cmd(KeyInput.left, option: true) == .previousBookmark)
        #expect(cmd(KeyInput.right, option: true) == .nextBookmark)
        #expect(cmd("b", option: true) == nil)
    }
}
