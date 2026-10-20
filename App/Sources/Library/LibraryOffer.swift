import Foundation

/// "Add this folder to the library?" — asked when a video is opened from a folder
/// the library does not cover (decision 2026-10-18: ask, never add silently).
/// Revised the same evening: every ordinary location is offered; broad folders
/// (home, Desktop, Downloads, Documents, a whole drive) as "this layer only", so a
/// video opened straight from Downloads is offered without pulling in everything below.
enum LibraryOffer {
    struct Proposal: Equatable {
        var path: String
        /// false: only the videos directly in the folder ("this layer only").
        var wholeFolder: Bool
    }

    /// What to offer for `filePath`, or nil if there is nothing to ask.
    static func proposal(forFile filePath: String, roots: [LibraryRoot], declined: Set<String>, neverAsk: Bool,
                         home: String = NSHomeDirectory()) -> Proposal? {
        guard !neverAsk, let folder = folder(of: filePath) else { return nil }
        let home = LibraryStore.normalized(home)
        guard !isSystem(folder, home: home), root(covering: folder, in: roots) == nil,
              !declined.contains(folder) else { return nil }
        return Proposal(path: folder, wholeFolder: !isBroad(folder, home: home))
    }

    /// The library folder that already lists videos directly in `folder`, if any.
    static func root(covering folder: String, in roots: [LibraryRoot]) -> String? {
        roots.first { $0.covers(LibraryStore.normalized(folder)) }?.path
    }

    /// The folder a local file sits in (nil for streams and relative paths).
    static func folder(of filePath: String) -> String? {
        guard filePath.hasPrefix("/") else { return nil }
        return LibraryStore.normalized((LibraryStore.normalized(filePath) as NSString).deletingLastPathComponent)
    }

    /// Folders that hold a little of everything: offered as their top layer only.
    static func isBroad(_ folder: String, home: String) -> Bool {
        let broad = Set([home] + ["Desktop", "Downloads", "Documents", "Pictures", "Music"].map { home + "/" + $0 })
        if broad.contains(folder) || folder == iCloudDrive(home) { return true }
        let parts = folder.split(separator: "/")
        return parts.count == 2 && parts[0] == "Volumes"                      // a whole drive
    }

    /// Never offered: the disk root, the folders that list users or drives, and
    /// temporary, trash and system locations.
    /// iCloud Drive lives under ~/Library but holds the user's own files.
    static func iCloudDrive(_ home: String) -> String { home + "/Library/Mobile Documents/com~apple~CloudDocs" }

    static func isSystem(_ folder: String, home: String) -> Bool {
        if ["/", "/Users", "/Volumes"].contains(folder) { return true }
        // Deleted files: ~/.Trash, and each drive's /.Trashes.
        if folder.split(separator: "/").contains(where: { $0 == ".Trashes" || $0 == ".Trash" }) { return true }
        let drive = iCloudDrive(home)
        if folder == drive || folder.hasPrefix(drive + "/") { return false }
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

    init(defaults: UserDefaults = AppData.defaults) { self.defaults = defaults }

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
    private let roots: () -> [LibraryRoot]
    private let show: (LibraryOffer.Proposal) -> Void
    private let add: (LibraryOffer.Proposal) -> Bool
    private let refresh: (String) -> Void

    init(preferences: LibraryOfferPreferences, home: String = NSHomeDirectory(), roots: @escaping () -> [LibraryRoot],
         show: @escaping (LibraryOffer.Proposal) -> Void, add: @escaping (LibraryOffer.Proposal) -> Bool,
         refresh: @escaping (String) -> Void) {
        self.preferences = preferences
        self.home = home
        self.roots = roots
        self.show = show
        self.add = add
        self.refresh = refresh
    }

    /// Already in the library: rescan that folder quietly so new videos join it.
    /// Otherwise: offer the folder (unless the rules say not to ask).
    func fileOpened(_ path: String) {
        let roots = roots()
        if let folder = LibraryOffer.folder(of: path), let root = LibraryOffer.root(covering: folder, in: roots) {
            refresh(root)
        } else if let proposal = LibraryOffer.proposal(forFile: path, roots: roots, declined: preferences.declined,
                                                       neverAsk: preferences.neverAsk, home: home) {
            show(proposal)
        }
    }

    @discardableResult
    func accept(_ proposal: LibraryOffer.Proposal) -> Bool { add(proposal) }
    func decline(_ folder: String) { preferences.decline(folder) }
    func neverAskAgain() { preferences.neverAsk = true }
}
