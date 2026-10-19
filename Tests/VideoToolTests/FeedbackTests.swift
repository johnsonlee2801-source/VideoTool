import Foundation
import Testing
@testable import VideoTool

// "发送反馈…" (decision 2026-10-19): opens a pre-filled GitHub issue. Only what the
// user chooses to send leaves the Mac; the template carries versions, nothing personal.
struct FeedbackTests {
    @Test("FB1 the link is a new issue on the project with a template and the versions")
    func link() throws {
        let url = Feedback.newIssueURL(appVersion: "0.2.0 (7)", system: "macOS 27.0")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https" && parts.host == "github.com")
        #expect(parts.path == "/johnsonlee2801-source/VideoTool/issues/new")
        let body = try #require(parts.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("0.2.0 (7)") && body.contains("macOS 27.0"))
        #expect(body.contains("遇到的问题") && body.contains("建议"))
    }

    @Test("FB2 the template is exactly the prompt plus the two versions: nothing else can slip in")
    func nothingPersonal() {
        #expect(Feedback.template(appVersion: "0.2.0 (7)", system: "macOS 27.0") == """
            **我遇到的问题 / 我的建议**


            **怎样能重现（如果是问题）**
            1.
            2.

            ---
            VideoTool 0.2.0 (7) · macOS 27.0
            """)
        let live = Feedback.template(appVersion: Feedback.appVersion, system: Feedback.systemVersion)
        for personal in [NSHomeDirectory(), NSUserName(), NSFullUserName(), Host.current().localizedName ?? "~"] where !personal.isEmpty {
            #expect(!live.contains(personal), "personal data in the feedback template")
        }
        #expect(Feedback.systemVersion.hasPrefix("macOS ") && Feedback.appVersion.contains("("))
    }
}
