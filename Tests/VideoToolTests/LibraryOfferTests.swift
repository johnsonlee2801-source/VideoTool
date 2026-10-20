import AppKit
import Testing
@testable import VideoTool

// Ask before adding (decision 2026-10-18), revised the same evening after the user
// opened a video straight from Downloads and was not asked: every ordinary
// location is offered; broad folders (home, Desktop, Downloads, Documents, a whole
// drive) are offered as "this layer only". Videos in folders already in the
// library are picked up by a quiet rescan instead of a question.
struct LibraryOfferPolicyTests {
    private let home = "/home/u"
    private func offer(_ file: String, roots: [LibraryRoot] = [], declined: Set<String> = [],
                       neverAsk: Bool = false) -> LibraryOffer.Proposal? {
        LibraryOffer.proposal(forFile: file, roots: roots, declined: declined, neverAsk: neverAsk, home: home)
    }
    private func deep(_ p: String) -> LibraryOffer.Proposal { .init(path: p, wholeFolder: true) }
    private func shallow(_ p: String) -> LibraryOffer.Proposal { .init(path: p, wholeFolder: false) }

    @Test("LO1 an ordinary folder is offered whole") func offersParent() {
        #expect(offer("/home/u/Movies/旅行/北海道.mp4") == deep("/home/u/Movies/旅行"))
        #expect(offer("/home/u/Downloads/美剧/S01E01.mkv") == deep("/home/u/Downloads/美剧"))
        #expect(offer("/home/u/Desktop/剪辑素材/a.mp4") == deep("/home/u/Desktop/剪辑素材"))
        #expect(offer("/Volumes/Media/Movies/a.mp4") == deep("/Volumes/Media/Movies"))
        #expect(offer("/home/u/Movies/a.mp4") == deep("/home/u/Movies"), "the Movies folder is meant for videos")
        #expect(offer("/home/u/Movies//旅行/./a.mp4") == deep("/home/u/Movies/旅行"))
    }

    @Test("LO2 broad folders are offered too, but only their top layer", arguments: [
        ("/home/u/Downloads/a.mp4", "/home/u/Downloads"), ("/home/u/Desktop/a.mp4", "/home/u/Desktop"),
        ("/home/u/Documents/a.mp4", "/home/u/Documents"), ("/home/u/a.mp4", "/home/u"),
        ("/home/u/Pictures/a.mp4", "/home/u/Pictures"), ("/Volumes/Media/a.mp4", "/Volumes/Media"),
    ])
    func broadFoldersShallow(file: String, folder: String) {
        #expect(offer(file) == shallow(folder))
    }

    @Test("LO3 system, temporary and trash folders are never offered", arguments: [
        "/a.mp4", "/Users/a.mp4", "/Volumes/a.mp4", "/private/var/folders/x/T/a.mp4", "/tmp/a.mp4",
        "/home/u/Library/Caches/a.mp4", "/home/u/.Trash/a.mp4", "/System/Library/a.mp4",
    ])
    func systemFolders(file: String) {
        #expect(offer(file) == nil)
    }

    @Test("LO4 folders already in the library are not offered; a this-layer-only folder still offers its sub-folders")
    func covered() {
        let roots = [LibraryRoot(path: "/home/u/Movies", recursive: true),
                     LibraryRoot(path: "/home/u/Downloads", recursive: false)]
        #expect(offer("/home/u/Movies/旅行/a.mp4", roots: roots) == nil)
        #expect(offer("/home/u/Movies/a.mp4", roots: roots) == nil)
        #expect(offer("/home/u/Downloads/a.mp4", roots: roots) == nil)
        #expect(offer("/home/u/Downloads/美剧/a.mp4", roots: roots) == deep("/home/u/Downloads/美剧"))
        #expect(offer("/home/u/Movies2/a.mp4", roots: roots) == deep("/home/u/Movies2"), "common prefix is not inside")
        #expect(LibraryOffer.root(covering: "/home/u/Movies/旅行", in: roots) == "/home/u/Movies")
        #expect(LibraryOffer.root(covering: "/home/u/Downloads/美剧", in: roots) == nil)
    }

    @Test("LO5 a declined folder is not offered again; 'don't ask again' stops all offers")
    func declinedAndNever() {
        #expect(offer("/home/u/Movies/旅行/a.mp4", declined: ["/home/u/Movies/旅行"]) == nil)
        #expect(offer("/home/u/Movies/其他/a.mp4", declined: ["/home/u/Movies/旅行"]) == deep("/home/u/Movies/其他"))
        #expect(offer("/home/u/Movies/旅行/a.mp4", neverAsk: true) == nil)
        #expect(offer("https://example.com/v.mp4") == nil)
    }
}

struct LibraryOfferPreferencesTests {
    @Test("LO6 declined folders and 'don't ask again' persist") func persists() throws {
        let suite = "videotool-tests-lo-\(UUID().uuidString)"
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

@MainActor struct LibraryOfferCoordinatorTests {
    private final class Rig {
        var roots: [LibraryRoot] = []
        var shown: [LibraryOffer.Proposal] = []
        var added: [LibraryOffer.Proposal] = []
        var refreshed: [String] = []
        let suite = "videotool-tests-loc-\(UUID().uuidString)"
        lazy var prefs = LibraryOfferPreferences(defaults: UserDefaults(suiteName: suite)!)
        lazy var coordinator = LibraryOfferCoordinator(
            preferences: prefs, home: "/home/u", roots: { self.roots },
            show: { self.shown.append($0) }, add: { self.added.append($0); return true }, refresh: { self.refreshed.append($0) })
        deinit { UserDefaults().removePersistentDomain(forName: suite) }
    }

    @Test("LO7 opening files from different places offers each place; 'add' adds what was offered")
    func eachLocation() {
        let r = Rig()
        r.coordinator.fileOpened("/home/u/Claude/out/a.mp4")
        r.coordinator.fileOpened("/home/u/Downloads/b.mp4")
        #expect(r.shown == [.init(path: "/home/u/Claude/out", wholeFolder: true),
                            .init(path: "/home/u/Downloads", wholeFolder: false)])
        r.coordinator.accept(r.shown[1])
        #expect(r.added == [.init(path: "/home/u/Downloads", wholeFolder: false)])
    }

    @Test("LO8 a video in a folder already in the library triggers a quiet rescan of that folder, no question")
    func rescanCovered() {
        let r = Rig()
        r.roots = [LibraryRoot(path: "/home/u/Movies", recursive: true)]
        r.coordinator.fileOpened("/home/u/Movies/旅行/new.mp4")
        #expect(r.shown.isEmpty)
        #expect(r.refreshed == ["/home/u/Movies"])
        r.prefs.neverAsk = true
        r.coordinator.fileOpened("/home/u/Movies/b.mp4")
        #expect(r.refreshed == ["/home/u/Movies", "/home/u/Movies"], "still picked up after 'don't ask again'")
    }

    @Test("LO9 'not this one' remembers the folder; 'never' stops offers everywhere") func declineFlow() {
        let r = Rig()
        r.coordinator.decline("/home/u/Movies/旅行")
        r.coordinator.fileOpened("/home/u/Movies/旅行/b.mp4")
        #expect(r.shown.isEmpty)
        r.coordinator.neverAskAgain()
        r.coordinator.fileOpened("/home/u/Movies/其他/c.mp4")
        #expect(r.shown.isEmpty)
        #expect(r.prefs.neverAsk)
    }
}

@Suite(.serialized) @MainActor struct LibraryOfferBarTests {
    @Test("LO10 the bar says whether the whole folder or only its top layer is added; buttons report it")
    func buttons() throws {
        let bar = LibraryOfferBar()
        var log: [String] = []
        bar.onAdd = { log.append("add \($0.path) \($0.wholeFolder)"); return true }
        bar.onDecline = { log.append("decline \($0)") }
        bar.onNeverAsk = { log.append("never") }
        bar.onOpenLibrary = { log.append("open") }
        bar.offer(.init(path: "/m/旅行", wholeFolder: true))
        #expect(!bar.isHidden)
        #expect(bar.message.contains("旅行") && !bar.message.contains("这一层"))
        bar.press(.add)
        #expect(log == ["add /m/旅行 true"])
        #expect(!bar.isHidden && bar.message.contains("已加入"))
        bar.press(.openLibrary)
        #expect(log.last == "open")
        #expect(bar.isHidden)
        bar.offer(.init(path: "/h/Downloads", wholeFolder: false))
        #expect(bar.message.contains("Downloads") && bar.message.contains("这一层"))
        bar.press(.decline)
        bar.offer(.init(path: "/m/三", wholeFolder: true)); bar.press(.neverAsk)
        #expect(log.suffix(2) == ["decline /h/Downloads", "never"])
        #expect(bar.isHidden)
    }
}


// Full-codebase audit 2026-10-20 (batch 02).
struct LibraryOfferAuditTests {
    @Test("LO20 deleted files on an external drive (.Trashes) are never offered")
    func externalTrash() {
        #expect(LibraryOffer.isSystem("/Volumes/Media/.Trashes/501/Old", home: "/home/u"))
        #expect(LibraryOffer.isSystem("/Volumes/Media/.Trashes", home: "/home/u"))
        #expect(!LibraryOffer.isSystem("/Volumes/Media/Movies", home: "/home/u"))
    }
}

struct ThumbnailSizeTests {
    @Test("TS1 frame sizes are bounded: a 16×16384 video cannot make a 900 MB buffer")
    func bounded() {
        let tall = MPVFrameGrabber.outputSize(requested: 480, videoWidth: 16, videoHeight: 16384)
        #expect(tall.height <= 480 * 4)
        let huge = MPVFrameGrabber.outputSize(requested: nil, videoWidth: 30000, videoHeight: 20000)
        #expect(huge.width <= MPVFrameGrabber.maxSide && huge.height <= MPVFrameGrabber.maxSide)
        #expect(MPVFrameGrabber.outputSize(requested: 480, videoWidth: 1920, videoHeight: 1080) == (480, 270))
        #expect(MPVFrameGrabber.outputSize(requested: nil, videoWidth: 640, videoHeight: 360) == (640, 360))
    }
}
