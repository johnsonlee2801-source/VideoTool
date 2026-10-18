import AppKit
import Testing
@testable import VideoTool

// "Ask once" (decision 2026-10-18): opening a video whose folder is not in the
// library offers to add that folder. Never for broad folders, folders already in
// the library, folders the user declined, or after "don't ask again".
struct LibraryOfferPolicyTests {
    private let home = "/home/u"
    private func offer(_ file: String, roots: [String] = [], declined: Set<String> = [], neverAsk: Bool = false) -> String? {
        LibraryOffer.folder(toOfferFor: file, roots: roots, declined: declined, neverAsk: neverAsk, home: home)
    }

    @Test("LO1 the video's own folder is offered") func offersParent() {
        #expect(offer("/home/u/Movies/旅行/北海道.mp4") == "/home/u/Movies/旅行")
        #expect(offer("/home/u/Downloads/美剧/S01E01.mkv") == "/home/u/Downloads/美剧")
        #expect(offer("/Volumes/Media/Movies/a.mp4") == "/Volumes/Media/Movies")
        #expect(offer("/home/u/Movies/a.mp4") == "/home/u/Movies", "the Movies folder is meant for videos")
        #expect(offer("/home/u/Movies//旅行/./a.mp4") == "/home/u/Movies/旅行")
    }

    @Test("LO2 nothing to offer when the folder is already in the library, or inside one")
    func coveredFolders() {
        #expect(offer("/home/u/Movies/旅行/a.mp4", roots: ["/home/u/Movies/旅行"]) == nil)
        #expect(offer("/home/u/Movies/旅行/a.mp4", roots: ["/home/u/Movies"]) == nil)
        #expect(offer("/home/u/Movies/旅行2/a.mp4", roots: ["/home/u/Movies/旅行"]) == "/home/u/Movies/旅行2",
                "a sibling with a common prefix is not covered")
    }

    @Test("LO3 broad, temporary and system folders are never offered", arguments: [
        "/home/u/a.mp4", "/home/u/Desktop/a.mp4", "/home/u/Downloads/a.mp4", "/home/u/Documents/a.mp4",
        "/home/u/Pictures/a.mp4", "/a.mp4", "/Users/a.mp4", "/Volumes/Media/a.mp4",
        "/private/var/folders/x/T/a.mp4", "/tmp/a.mp4", "/home/u/Library/Caches/a.mp4", "/home/u/.Trash/a.mp4",
        "/home/u/Library/Mobile Documents/com~apple~CloudDocs/a.mp4",
    ])
    func broadFolders(file: String) {
        #expect(offer(file) == nil)
    }

    @Test("LO4 a declined folder is not offered again; 'don't ask again' stops all offers")
    func declinedAndNever() {
        #expect(offer("/home/u/Movies/旅行/a.mp4", declined: ["/home/u/Movies/旅行"]) == nil)
        #expect(offer("/home/u/Movies/其他/a.mp4", declined: ["/home/u/Movies/旅行"]) == "/home/u/Movies/其他")
        #expect(offer("/home/u/Movies/旅行/a.mp4", neverAsk: true) == nil)
    }
}

struct LibraryOfferPreferencesTests {
    @Test("LO5 declined folders and 'don't ask again' persist") func persists() throws {
        let suite = "lo-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = LibraryOfferPreferences(defaults: defaults)
        #expect(!a.neverAsk && a.declined.isEmpty)
        a.decline("/x/旅行")
        a.neverAsk = true
        let b = LibraryOfferPreferences(defaults: defaults)
        #expect(b.declined == ["/x/旅行"])
        #expect(b.neverAsk)
    }
}

// The coordinator joins the policy, the preferences, the library and the bar.
@MainActor struct LibraryOfferCoordinatorTests {
    private final class Rig {
        var roots: [String] = []
        var shown: [String] = []
        var added: [String] = []
        let suite = "loc-\(UUID().uuidString)"
        lazy var prefs = LibraryOfferPreferences(defaults: UserDefaults(suiteName: suite)!)
        lazy var coordinator = LibraryOfferCoordinator(
            preferences: prefs, home: "/home/u", roots: { self.roots },
            show: { self.shown.append($0) }, add: { self.added.append($0) })
        deinit { UserDefaults().removePersistentDomain(forName: suite) }
    }

    @Test("LO6 opening a file offers its folder; 'add' adds it to the library") func addFlow() {
        let r = Rig()
        r.coordinator.fileOpened("/home/u/Movies/旅行/a.mp4")
        #expect(r.shown == ["/home/u/Movies/旅行"])
        r.coordinator.accept("/home/u/Movies/旅行")
        #expect(r.added == ["/home/u/Movies/旅行"])
    }

    @Test("LO7 'not this one' remembers the folder; 'never' stops offers for every folder")
    func declineFlow() {
        let r = Rig()
        r.coordinator.decline("/home/u/Movies/旅行")
        r.coordinator.fileOpened("/home/u/Movies/旅行/b.mp4")
        #expect(r.shown.isEmpty)
        r.coordinator.neverAskAgain()
        r.coordinator.fileOpened("/home/u/Movies/其他/c.mp4")
        #expect(r.shown.isEmpty)
        #expect(r.prefs.neverAsk)
    }

    @Test("LO8 web streams and folders already in the library are not offered") func skips() {
        let r = Rig()
        r.roots = ["/home/u/Movies"]
        r.coordinator.fileOpened("/home/u/Movies/旅行/a.mp4")
        r.coordinator.fileOpened("https://example.com/v.mp4")
        #expect(r.shown.isEmpty)
    }
}

@Suite(.serialized) @MainActor struct LibraryOfferBarTests {
    @Test("LO9 the bar's buttons report the folder; after adding it confirms and offers to open the library")
    func buttons() throws {
        let bar = LibraryOfferBar()
        var log: [String] = []
        bar.onAdd = { log.append("add \($0)") }
        bar.onDecline = { log.append("decline \($0)") }
        bar.onNeverAsk = { log.append("never") }
        bar.onOpenLibrary = { log.append("open") }
        bar.offer("/m/旅行")
        #expect(!bar.isHidden)
        #expect(bar.message.contains("旅行"))
        bar.press(.add)
        #expect(log == ["add /m/旅行"])
        #expect(!bar.isHidden && bar.message.contains("已加入"))
        bar.press(.openLibrary)
        #expect(log.last == "open")
        #expect(bar.isHidden)
        bar.offer("/m/其他"); bar.press(.decline)
        bar.offer("/m/三"); bar.press(.neverAsk)
        #expect(log.suffix(2) == ["decline /m/其他", "never"])
        #expect(bar.isHidden)
    }
}
