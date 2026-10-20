import Foundation

/// Where VideoTool keeps its own data. Under the test runner everything goes to a
/// throwaway folder and preference domain, so tests never touch the user's real
/// library, stars, resume positions or answers (found 2026-10-18: UI tests that
/// open a player window were opening the real database).
enum AppData {
    static let isTestRun: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    /// Prefix of every test run's folder and of every preference domain tests create.
    static let testPrefix = "videotool-tests-"

    /// ~/Library/Application Support/VideoTool, or a per-run temp folder under tests
    /// (earlier runs' leftovers are removed the first time it is used).
    static let directory: URL = {
        guard isTestRun else {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VideoTool", isDirectory: true)
        }
        cleanUpStaleTestData()
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(testPrefix)\(getpid())", isDirectory: true)
    }()

    /// The preference domain behind `defaults` (for reading only what is stored there).
    static let defaultsDomain: String = isTestRun ? "\(testPrefix)\(getpid())" : (Bundle.main.bundleIdentifier ?? "")

    static let defaults: UserDefaults = isTestRun
        ? UserDefaults(suiteName: "\(testPrefix)\(getpid())")!     // never the user's real preferences
        : .standard

    /// Removes test-run folders and test preference files older than `age`, except
    /// this run's. Only names starting with `testPrefix` are ever touched; the temp
    /// folder is shared with other apps.
    @discardableResult
    static func cleanUpStaleTestData(tempDirectory: URL = FileManager.default.temporaryDirectory,
                                     preferencesDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                                        .appendingPathComponent("Preferences"),
                                     currentPID: Int32 = getpid(), age: TimeInterval = 3600, now: Date = Date()) -> [String] {
        var removed: [String] = []
        let fm = FileManager.default
        let mine = "\(testPrefix)\(currentPID)"
        for dir in [tempDirectory, preferencesDirectory] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.lowercased().hasPrefix(testPrefix) {
                let stem = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
                guard stem.lowercased() != mine else { continue }
                let url = dir.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
                guard now.timeIntervalSince(modified) > age else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed.append(name) }
            }
        }
        return removed
    }
}

/// One folder per test run for everything tests write (see AppData).
enum TestTemp {
    static var directory: URL {
        let dir = AppData.directory.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
