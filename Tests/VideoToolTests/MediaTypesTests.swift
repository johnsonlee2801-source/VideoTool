import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VideoTool

@Suite struct MediaTypesTests {
    @Test("extensions are lowercase, unique and non-empty") func wellFormed() {
        let all = MediaTypes.allExtensions
        #expect(!all.isEmpty)
        #expect(Set(all).count == all.count, "duplicate extension")
        #expect(all.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty && !$0.hasPrefix(".") })
    }

    @Test("the everyday formats are covered") func everyday() {
        for ext in ["mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "wmv", "rmvb", "mp3", "flac", "m4a"] {
            #expect(MediaTypes.allExtensions.contains(ext), "\(ext)")
        }
    }

    @Test("isMedia is case-insensitive on the extension") func isMedia() {
        #expect(MediaTypes.isMedia(URL(fileURLWithPath: "/tmp/a.MKV")))
        #expect(MediaTypes.isMedia(URL(fileURLWithPath: "/tmp/b.mp4")))
        #expect(!MediaTypes.isMedia(URL(fileURLWithPath: "/tmp/c.txt")))
        #expect(!MediaTypes.isMedia(URL(fileURLWithPath: "/tmp/noext")))
    }

    @Test("UTType list has no duplicates and includes the generic movie type") func utTypes() {
        let ids = MediaTypes.utTypes.map(\.identifier)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("public.movie"))
        #expect(ids.contains("public.audio"))
    }

    @Test("the app's Info.plist claims every extension MediaTypes lists") func infoPlistCoverage() throws {
        let bundle = Bundle(for: AppDelegate.self)
        let docTypes = try #require(bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        var claimed = Set<String>()
        for t in docTypes {
            for e in (t["CFBundleTypeExtensions"] as? [String]) ?? [] { claimed.insert(e.lowercased()) }
        }
        let missing = MediaTypes.allExtensions.filter { !claimed.contains($0) }
        #expect(missing.isEmpty, "Info.plist is missing: \(missing)")
        let roles = Set(docTypes.compactMap { $0["CFBundleTypeRole"] as? String })
        #expect(roles == ["Viewer"])
    }

    @Test("every imported UTI used by a document type is declared") func importedTypesDeclared() throws {
        let bundle = Bundle(for: AppDelegate.self)
        let docTypes = try #require(bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let imported = Set(((bundle.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [])
            .compactMap { $0["UTTypeIdentifier"] as? String })
        let used = docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] }
        for id in used where id.hasPrefix("io.github.johnsonlee2801-source.") {
            #expect(imported.contains(id), "\(id) is used but not declared")
        }
    }

    @Test("every extension really routes to the app: its system type conforms to a claimed content type, or an imported declaration claims it")
    func extensionsRouteToApp() throws {
        let info = try #require(Bundle(for: AppDelegate.self).infoDictionary)
        let docTypes = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let claimed = Set(docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })
        var importedByExt: [String: String] = [:]
        for decl in (info["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [] {
            guard let id = decl["UTTypeIdentifier"] as? String,
                  let tags = decl["UTTypeTagSpecification"] as? [String: Any] else { continue }
            for e in (tags["public.filename-extension"] as? [String]) ?? [] { importedByExt[e] = id }
        }
        let claimedTypes = claimed.compactMap { UTType($0) }
        var unrouted: [String] = []
        for ext in MediaTypes.allExtensions {
            if let id = importedByExt[ext], claimed.contains(id) { continue }
            if let t = UTType(filenameExtension: ext), !t.isDynamic,
               claimedTypes.contains(where: { t.conforms(to: $0) }) { continue }
            unrouted.append(ext)
        }
        #expect(unrouted.isEmpty, "Launch Services would not route: \(unrouted)")
    }

    @Test("default-player registration covers video types only (mp3/flac keep their app)") func videoOnlyDefaults() {
        let ids = Set(MediaTypes.videoUTTypes.map(\.identifier))
        #expect(ids.contains("public.mpeg-4") && ids.contains("com.apple.quicktime-movie"))
        #expect(!ids.contains("public.mp3") && !ids.contains("public.audio"))
        #expect(MediaTypes.videoUTTypes.allSatisfy { $0.conforms(to: .movie) || $0.conforms(to: .video) || $0.conforms(to: .audiovisualContent) })
    }
}
