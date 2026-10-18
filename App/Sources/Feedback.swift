import AppKit

/// "发送反馈…": opens a new GitHub issue pre-filled with a short template and the
/// app and macOS versions. Nothing is sent automatically and no usage data is
/// collected; the user sees and edits everything before submitting.
enum Feedback {
    static let issuesURL = URL(string: "https://github.com/johnsonlee2801-source/VideoTool/issues/new")!

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    static func template(appVersion: String, system: String) -> String {
        """
        **我遇到的问题 / 我的建议**


        **怎样能重现（如果是问题）**
        1.
        2.

        ---
        VideoTool \(appVersion) · \(system)
        """
    }

    static func newIssueURL(appVersion: String = appVersion, system: String = systemVersion) -> URL {
        var parts = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "body", value: template(appVersion: appVersion, system: system))]
        return parts.url!
    }

    static func open() { NSWorkspace.shared.open(newIssueURL()) }
}
