import Foundation
import Testing
@testable import VideoTool

// Every library shipped inside the app must be listed with its licence. Fails as
// soon as a dependency update adds a framework nobody has documented.

@Suite struct ThirdPartyNoticesTests {
    private var notices: String? {
        Bundle(for: AppDelegate.self).url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    @Test("TP1 the notices file ships inside the app") func ships() {
        #expect(notices?.contains("LGPL-2.1-or-later") == true)
    }

    @Test("TP2 every framework in Contents/Frameworks is listed in the notices") func everyFrameworkListed() throws {
        let text = try #require(notices)
        let dir = try #require(Bundle(for: AppDelegate.self).privateFrameworksURL)
        let shipped = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".framework") }
            .map { String($0.dropLast(".framework".count)) }
            .filter { !$0.hasPrefix("VideoToolCore") }        // our own code (debug builds add a suffix)
        #expect(!shipped.isEmpty, "expected the MPVKit frameworks in \(dir.path)")
        let missing = shipped.filter { !text.contains($0) }
        #expect(missing.isEmpty, "undocumented frameworks: \(missing)")
    }

    @Test("TP3 nothing GPL-only is shipped: the GPL MPVKit variant is not linked") func noGPLVariant() throws {
        let dir = try #require(Bundle(for: AppDelegate.self).privateFrameworksURL)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.contains("GPL") || $0.lowercased().contains("smbclient") }, "\(names)")
    }
}
