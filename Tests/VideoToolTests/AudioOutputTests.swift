import AppKit
import Testing
@testable import VideoTool

struct AudioOutputTests {
    private let listed = [AudioDevice(name: "auto", description: "Autoselect device"),
                          AudioDevice(name: "coreaudio/BuiltInSpeakerDevice", description: "MacBook Pro扬声器"),
                          AudioDevice(name: "avfoundation/BuiltInSpeakerDevice", description: "MacBook Pro扬声器"),
                          AudioDevice(name: "coreaudio/AirPlay", description: "客厅 HomePod")]

    @Test("AO1 the menu offers 'follow the system' and each output once, the current one ticked") func menu() {
        let items = AudioOutput.menu(devices: listed, current: "coreaudio/AirPlay", target: nil, action: nil)
        #expect(items.map(\.title) == ["跟随系统", "MacBook Pro扬声器", "客厅 HomePod"])
        #expect(items.filter { $0.state == .on }.map(\.title) == ["客厅 HomePod"])
        #expect(items.compactMap { $0.representedObject as? String } == ["auto", "coreaudio/BuiltInSpeakerDevice", "coreaudio/AirPlay"])
    }

    @Test("AO2 the chosen output is remembered and used again only while it is there") func remembered() throws {
        let suite = "videotool-tests-ao-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let p = AudioOutputPreference(defaults: d)
        #expect(p.device == "auto")
        p.device = "coreaudio/AirPlay"
        #expect(AudioOutputPreference(defaults: d).resolved(among: listed) == "coreaudio/AirPlay")
        #expect(AudioOutputPreference(defaults: d).resolved(among: Array(listed.prefix(2))) == "auto", "HomePod gone: follow the system")
    }
}

@Suite(.serialized) @MainActor struct AudioOutputEngineTests {
    @Test("AO3 the real engine lists this Mac's outputs and switches between them") func realEngine() async throws {
        let engine = try MPVEngine()
        defer { engine.shutdown() }
        let devices = engine.audioDevices()
        #expect(devices.first?.name == "auto")
        let choices = AudioOutput.choices(from: devices)
        #expect(choices.count >= 2, "at least 'follow the system' and one Core Audio output: \(devices)")
        let target = choices[1].name
        engine.setAudioDevice(target)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, engine.property("audio-device") != target { try await Task.sleep(for: .milliseconds(20)) }
        #expect(engine.property("audio-device") == target)
        engine.setAudioDevice("auto")
    }
}
