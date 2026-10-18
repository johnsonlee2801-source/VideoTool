import Foundation
import Libmpv
import Testing
@testable import VideoTool

// How mpv property-change notifications become PlayerState, without running mpv.
struct MPVPropertyTests {
    @Test("MP1 every observed property has its mpv name and the format it is read in")
    func namesAndFormats() {
        let table = Dictionary(uniqueKeysWithValues: MPVProperty.allCases.map { ($0.name, $0.format) })
        #expect(table == ["time-pos": MPV_FORMAT_DOUBLE, "duration": MPV_FORMAT_DOUBLE, "speed": MPV_FORMAT_DOUBLE,
                          "volume": MPV_FORMAT_DOUBLE, "pause": MPV_FORMAT_FLAG, "mute": MPV_FORMAT_FLAG,
                          "eof-reached": MPV_FORMAT_FLAG, "idle-active": MPV_FORMAT_FLAG,
                          "media-title": MPV_FORMAT_STRING, "path": MPV_FORMAT_STRING])
        #expect(MPVProperty.allCases.allSatisfy { $0.rawValue != 0 }, "0 is mpv's 'no userdata'")
    }

    @Test("MP2 values land in the matching state field", arguments: [
        (MPVProperty.timePos, MPVValue.double(12.5), \PlayerState.timePos as PartialKeyPath<PlayerState>, 12.5 as AnyHashable),
        (.duration, .double(90), \PlayerState.duration, 90.0),
        (.speed, .double(2.4), \PlayerState.speed, 2.4),
        (.volume, .double(35), \PlayerState.volume, 35.0),
        (.pause, .flag(false), \PlayerState.isPaused, false),
        (.mute, .flag(true), \PlayerState.isMuted, true),
        (.eofReached, .flag(true), \PlayerState.eofReached, true),
        (.idleActive, .flag(false), \PlayerState.isIdle, false),
        (.mediaTitle, .string("Tokyo"), \PlayerState.mediaTitle, "Tokyo"),
    ])
    func applies(prop: MPVProperty, value: MPVValue, field: PartialKeyPath<PlayerState>, expected: AnyHashable) {
        var s = PlayerState()
        do { let changed = s.apply(prop, value); #expect(changed) }
        #expect(s[keyPath: field] as? AnyHashable == expected)
    }

    @Test("MP3 a property that becomes unavailable resets to its idle value")
    func unavailable() {
        var s = PlayerState(isPaused: false, speed: 2, timePos: 40, duration: 90, volume: 50, isMuted: true,
                            mediaTitle: "x", path: "/a", isIdle: false, eofReached: true)
        for p in [MPVProperty.timePos, .duration, .path, .mediaTitle, .eofReached, .idleActive] { do { let changed = s.apply(p, .unavailable); #expect(changed) } }
        #expect(s == PlayerState(isPaused: false, speed: 2, timePos: 0, duration: 0, volume: 50, isMuted: true,
                                 mediaTitle: "", path: nil, isIdle: true, eofReached: false))
        // Settings keep their last value when mpv cannot report them.
        for p in [MPVProperty.speed, .volume, .pause, .mute] { do { let changed = s.apply(p, .unavailable); #expect(!changed) } }
    }

    @Test("MP4 a value of the wrong type, or a null string, changes nothing (except clearing the path)")
    func mismatches() {
        let start = PlayerState(mediaTitle: "kept", path: "/a")
        var s = start
        do { let changed = s.apply(.speed, .flag(true)); #expect(!changed) }
        do { let changed = s.apply(.pause, .double(1)); #expect(!changed) }
        do { let changed = s.apply(.timePos, .string("3")); #expect(!changed) }
        do { let changed = s.apply(.mediaTitle, .string(nil)); #expect(!changed) }
        #expect(s == start)
        do { let changed = s.apply(.path, .string(nil)); #expect(changed) }
        #expect(s.path == nil)
        do { let changed = s.apply(.path, .string("/v/a.mp4")); #expect(changed) }
        #expect(s.path == "/v/a.mp4")
    }

    @Test("MP5 decoding mpv's C struct") func decode() {
        var d = 7.25
        var flag: Int32 = 1
        let text = strdup("片名")!
        defer { free(text) }
        var textPtr: UnsafeMutablePointer<CChar>? = text
        var nullPtr: UnsafeMutablePointer<CChar>? = nil
        func event(_ format: mpv_format, _ data: UnsafeMutableRawPointer?) -> mpv_event_property {
            mpv_event_property(name: nil, format: format, data: data)
        }
        #expect(MPVValue(event(MPV_FORMAT_DOUBLE, &d)) == .double(7.25))
        #expect(MPVValue(event(MPV_FORMAT_FLAG, &flag)) == .flag(true))
        #expect(MPVValue(event(MPV_FORMAT_STRING, &textPtr)) == .string("片名"))
        #expect(MPVValue(event(MPV_FORMAT_STRING, &nullPtr)) == .string(nil))
        #expect(MPVValue(event(MPV_FORMAT_NONE, nil)) == .unavailable)
        #expect(MPVValue(event(MPV_FORMAT_DOUBLE, nil)) == nil)
        #expect(MPVValue(event(MPV_FORMAT_INT64, &d)) == nil)
    }
}
