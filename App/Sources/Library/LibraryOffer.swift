import Foundation

/// "Add this folder to the library?" — offered once when a video is opened from a
/// folder the library does not know (decision 2026-10-18: ask, never add silently).
enum LibraryOffer {
    /// The folder to offer for `filePath`, or nil if there is nothing worth asking.
    static func folder(toOfferFor filePath: String, roots: [String], declined: Set<String>, neverAsk: Bool,
                       home: String = NSHomeDirectory()) -> String? {
        guard !neverAsk, filePath.hasPrefix("/") else { return nil }
        let folder = LibraryStore.normalized((LibraryStore.normalized(filePath) as NSString).deletingLastPathComponent)
        guard !isBroadOrSystem(folder, home: LibraryStore.normalized(home)) else { return nil }
        if roots.map(LibraryStore.normalized).contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) { return nil }
        if declined.contains(folder) { return nil }
        return folder
    }

    /// Folders too big or too unrelated to index whole: they would pull in every
    /// video anywhere below them (or temporary/system files).
    static func isBroadOrSystem(_ folder: String, home: String) -> Bool {
        let broad = Set(["/", "/Users", "/Volumes", home]).union(
            ["Desktop", "Downloads", "Documents", "Pictures", "Music"].map { home + "/" + $0 })
        if broad.contains(folder) { return true }
        let parts = folder.split(separator: "/")
        if parts.count == 2 && parts[0] == "Volumes" { return true }                 // a whole drive
        let system = ["/tmp", "/private", "/var", "/System", "/Library", "/Applications",
                      home + "/Library", home + "/.Trash"]
        return system.contains { folder == $0 || folder.hasPrefix($0 + "/") }
    }
}

/// What the user answered to earlier offers.
final class LibraryOfferPreferences {
    static let declinedKey = "videotool.library-offer.declined"
    static let neverAskKey = "videotool.library-offer.never-ask"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var declined: Set<String> { Set(defaults.stringArray(forKey: Self.declinedKey) ?? []) }
    func decline(_ folder: String) {
        defaults.set(Array(declined.union([folder])).sorted(), forKey: Self.declinedKey)
    }
    var neverAsk: Bool {
        get { defaults.bool(forKey: Self.neverAskKey) }
        set { defaults.set(newValue, forKey: Self.neverAskKey) }
    }
}

/// Joins the rule, the saved answers, the library and the on-screen bar.
final class LibraryOfferCoordinator {
    private let preferences: LibraryOfferPreferences
    private let home: String
    private let roots: () -> [String]
    private let show: (String) -> Void
    private let add: (String) -> Void

    init(preferences: LibraryOfferPreferences, home: String = NSHomeDirectory(), roots: @escaping () -> [String],
         show: @escaping (String) -> Void, add: @escaping (String) -> Void) {
        self.preferences = preferences
        self.home = home
        self.roots = roots
        self.show = show
        self.add = add
    }

    func fileOpened(_ path: String) {
        if let folder = LibraryOffer.folder(toOfferFor: path, roots: roots(), declined: preferences.declined,
                                            neverAsk: preferences.neverAsk, home: home) {
            show(folder)
        }
    }

    func accept(_ folder: String) { add(folder) }
    func decline(_ folder: String) { preferences.decline(folder) }
    func neverAskAgain() { preferences.neverAsk = true }
}
