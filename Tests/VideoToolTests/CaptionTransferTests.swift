import Foundation
import Testing
@testable import VideoTool

@Suite @MainActor struct CaptionTransferTests {
    private let track = NetworkCaptionTrack(id: "en", title: "English", format: "json3", site: .youtube,
        url: URL(string: "https://www.youtube.com/api/timedtext"), inline: nil, headers: [:])
    @Test("CT1 HTTP restrictions and oversized bodies fail once with a safe category")
    func bounds() throws {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let url = try #require(track.url)
        let task = session.dataTask(with: url)
        var errors: [SubtitleLoadFailure] = []
        let transfer = CaptionTransfer(track: track) { if case .failure(let error) = $0 { errors.append(error) } }
        var disposition: URLSession.ResponseDisposition?
        transfer.urlSession(session, dataTask: task, didReceive: Data(repeating: 0, count: SubtitleTranscript.maxBytes + 1))
        transfer.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(errors == [.tooLarge])
        let restricted = CaptionTransfer(track: track) { if case .failure(let error) = $0 { errors.append(error) } }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil))
        restricted.urlSession(session, dataTask: task, didReceive: response) { disposition = $0 }
        #expect(disposition == .cancel && errors.last == .restricted)
    }
    @Test("CT2 redirects cannot escape the source site, and cancellation discards delivery")
    func redirectsAndCancel() throws {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let url = try #require(track.url)
        let task = session.dataTask(with: url)
        var error: SubtitleLoadFailure?
        let transfer = CaptionTransfer(track: track) { if case .failure(let value) = $0 { error = value } }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        var allowed = true
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://youtube.com.evil.test/api/timedtext")!)) { allowed = $0 != nil }
        #expect(!allowed && error == .restricted)
        var callbacks = 0
        let cancelled = CaptionTransfer(track: track) { _ in callbacks += 1 }
        cancelled.cancel(); cancelled.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(callbacks == 0)
    }
}
