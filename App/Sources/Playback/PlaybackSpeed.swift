import AppKit

/// Fixed playback speeds (decision 2026-10-19): picked from the speed label next
/// to the timeline or the Play menu, remembered across launches.
enum PlaybackSpeed {
    static let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
    static let range = 0.5...6.0

    /// In range, on 0.05 steps (so 1.1 + 0.1 is 1.2, not 1.2000000000000002).
    static func normalized(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        let stepped = (speed * 20).rounded() / 20
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// "1.0×", "1.25×", "2.5×": one decimal unless a quarter step needs two.
    static func label(_ speed: Double) -> String {
        let s = normalized(speed)
        let tenths = (s * 10).rounded() / 10
        return abs(s - tenths) < 0.001 ? String(format: "%.1f×", tenths) : String(format: "%.2f×", s)
    }

    /// One item per preset, the current speed ticked; each item carries its speed.
    static func menu(current: Double, target: AnyObject?, action: Selector?) -> NSMenu {
        let menu = NSMenu(title: "播放速度")
        for p in presets {
            let item = NSMenuItem(title: label(p), action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = p
            item.state = abs(p - current) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// The speed the user last chose (not the temporary speed of a hold).
final class PreferredSpeedStore {
    static let key = "videotool.preferred-speed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppData.defaults) { self.defaults = defaults }

    var speed: Double {
        get {
            let v = defaults.double(forKey: Self.key)
            return PlaybackSpeed.range.contains(v) ? PlaybackSpeed.normalized(v) : 1.0
        }
        set { defaults.set(PlaybackSpeed.normalized(newValue), forKey: Self.key) }
    }
}
