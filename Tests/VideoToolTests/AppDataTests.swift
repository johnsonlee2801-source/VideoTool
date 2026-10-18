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
