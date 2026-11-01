import Foundation

enum PlayerSidebarTab: Int, CaseIterable { case library, recent, stars }

struct PlayerSidebarState: Equatable {
    var isExpanded = false
    var tab: PlayerSidebarTab = .library
    var preferredWidth: CGFloat = 380
    mutating func show(_ tab: PlayerSidebarTab) { self.tab = tab; isExpanded = true }
    mutating func toggleStars() {
        if isExpanded && tab == .stars { close() } else { show(.stars) }
    }
    mutating func close() { isExpanded = false }
    var boundedWidth: CGFloat { preferredWidth.isFinite ? min(560, max(280, preferredWidth)) : 380 }
    func fittedWidth(available: CGFloat) -> CGFloat {
        guard isExpanded, available.isFinite else { return 0 }
        return max(0, min(boundedWidth, available - 240))
    }
}

final class PlayerSidebarPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = AppData.defaults) { self.defaults = defaults }
    func load() -> PlayerSidebarState {
        var s = PlayerSidebarState()
        s.isExpanded = defaults.bool(forKey: "videotool.sidebar.expanded")
        s.tab = PlayerSidebarTab(rawValue: defaults.integer(forKey: "videotool.sidebar.tab")) ?? .library
        if defaults.object(forKey: "videotool.sidebar.width") != nil {
            s.preferredWidth = defaults.double(forKey: "videotool.sidebar.width")
            s.preferredWidth = s.boundedWidth
        }
        return s
    }
    func save(_ state: PlayerSidebarState) {
        defaults.set(state.isExpanded, forKey: "videotool.sidebar.expanded")
        defaults.set(state.tab.rawValue, forKey: "videotool.sidebar.tab")
        defaults.set(state.boundedWidth, forKey: "videotool.sidebar.width")
    }
}
