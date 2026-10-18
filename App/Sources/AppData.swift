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

    /// ~/Library/Application Support/VideoTool, or a per-run temp folder under tests.
    static let directory: URL = isTestRun
        ? FileManager.default.temporaryDirectory.appendingPathComponent("VideoTool-tests-\(getpid())", isDirectory: true)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoTool", isDirectory: true)

    static let defaults: UserDefaults = isTestRun
        ? UserDefaults(suiteName: "videotool-tests-\(getpid())") ?? .standard
        : .standard
}
