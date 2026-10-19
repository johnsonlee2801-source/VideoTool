import AppKit

/// Choosing where the sound goes (decision 2026-10-19, casting step 1): the Mac's
/// speakers, headphones, or AirPlay speakers such as HomePod, as macOS lists them.
struct AudioDevice: Equatable {
    var name: String          // mpv's id, e.g. "coreaudio/BuiltInSpeakerDevice"; "auto" follows the system
    var description: String
}

enum AudioOutput {
    static let followSystem = "auto"

    /// mpv lists each device once per audio API; keep "auto" and the Core Audio ones.
    static func choices(from devices: [AudioDevice]) -> [AudioDevice] {
        var out = [AudioDevice(name: followSystem, description: "跟随系统")]
        var seen = Set<String>()
        for d in devices where d.name.hasPrefix("coreaudio/") && seen.insert(d.description).inserted {
            out.append(d)
        }
        return out
    }

    static func menu(devices: [AudioDevice], current: String, target: AnyObject?, action: Selector?) -> [NSMenuItem] {
        choices(from: devices).map { d in
            let item = NSMenuItem(title: d.description, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = d.name
            item.state = d.name == current ? .on : .off
            return item
        }
    }
}

/// The output chosen last time; used again if that device is still there.
final class AudioOutputPreference {
    static let key = "videotool.audio-device"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = AppData.defaults) { self.defaults = defaults }

    var device: String {
        get { defaults.string(forKey: Self.key) ?? AudioOutput.followSystem }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    /// What to use now: the saved device if present, else follow the system.
    func resolved(among devices: [AudioDevice]) -> String {
        devices.contains { $0.name == device } ? device : AudioOutput.followSystem
    }
}
