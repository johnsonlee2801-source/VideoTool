import Foundation
import Testing
@testable import VideoTool

// Tests must never read or write the user's real data (2026-10-18).
struct AppDataTests {
    @Test("AD1 under tests, the database, thumbnails and preferences are throwaway copies") func isolated() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        #expect(AppData.isTestRun)
        #expect(!SQLiteDatabase.defaultPath.hasPrefix(real))
        #expect(!LibraryIndexer.defaultThumbnailDirectory.path.hasPrefix(real))
        #expect(SQLiteDatabase.defaultPath.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(AppData.defaults !== UserDefaults.standard)
    }
}

struct TestDataCleanupTests {
    @Test("AD2 earlier runs' folders and test preference files go; this run's, recent ones and others' files stay")
    func cleanup() throws {
        let base = TestTemp.directory.appendingPathComponent("ad2-\(UUID().uuidString)")
        let temp = base.appendingPathComponent("T"), prefs = base.appendingPathComponent("Preferences")
        let fm = FileManager.default
        for d in [temp, prefs] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let old = Date().addingTimeInterval(-7200)
        func make(_ dir: URL, _ name: String, at date: Date) throws {
            let url = dir.appendingPathComponent(name)
            try Data().write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try make(temp, "videotool-tests-111", at: old)            // an earlier run: goes
        try make(temp, "videotool-tests-999", at: old)            // this run (pid 999): stays
        try make(temp, "videotool-tests-222", at: Date())         // a run still going: stays
        try make(temp, "com.other.app-cache", at: old)            // someone else's: stays
        try make(temp, "videotool-quality", at: old)              // opt-in suites' clips: stay
        try make(prefs, "videotool-tests-111.plist", at: old)
        try make(prefs, "videotool-tests-lo-ABC.plist", at: old)
        try make(prefs, "videotool-tests-999.plist", at: old)
        try make(prefs, "io.github.someone.app.plist", at: old)
        let removed = AppData.cleanUpStaleTestData(tempDirectory: temp, preferencesDirectory: prefs, currentPID: 999)
        #expect(Set(removed) == ["videotool-tests-111", "videotool-tests-111.plist", "videotool-tests-lo-ABC.plist"])
        #expect(Set(try fm.contentsOfDirectory(atPath: temp.path)) == ["videotool-tests-999", "videotool-tests-222", "com.other.app-cache", "videotool-quality"])
        #expect(Set(try fm.contentsOfDirectory(atPath: prefs.path)) == ["videotool-tests-999.plist", "io.github.someone.app.plist"])
    }
}

struct SilentTestsTests {
    @Test("AD3 under tests the player decodes audio but plays it nowhere") func silent() {
        #expect(MPVEngine.testOptions.contains { $0 == ("ao", "null") })
    }
}
