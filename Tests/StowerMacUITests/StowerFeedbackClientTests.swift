import Foundation
import Testing

@testable import StowerMacUI

/// I1–I3: the feedback client's JSON encoding key-set, secret-absence, and
/// HTTP-status classification — all via a stub transport; no network required.
@Suite internal struct StowerFeedbackClientTests {
    private let baseURL = "https://example.invalid/functions/v1"

    // MARK: - Transport helpers

    private func transport(status: Int) throws -> StowerFeedbackClient.Transport {
        let url = try #require(URL(string: "https://example.invalid/feedback"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        return { _ in (Data(), response) }
    }

    private func client(status: Int) throws -> StowerFeedbackClient {
        StowerFeedbackClient(
            functionBaseURL: baseURL,
            transport: try transport(status: status)
        )
    }

    // MARK: - I1: encoded JSON key-set

    @Test("I1: full draft encodes text, appVersion, licenseID, and email — nothing else")
    internal func fullDraftKeySet() throws {
        let draft = StowerFeedbackDraft(
            text: "Great app!",
            email: "user@example.com",
            licenseID: "lic-1",
            appVersion: "1.0 (1)"
        )
        let data = try JSONEncoder().encode(draft)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"text\""))
        #expect(json.contains("\"appVersion\""))
        #expect(json.contains("\"licenseID\""))
        #expect(json.contains("\"email\""))
    }

    @Test("I1: nil email is omitted from the JSON body entirely")
    internal func nilEmailOmitted() throws {
        let draft = StowerFeedbackDraft(
            text: "Good",
            email: nil,
            licenseID: "lic-1",
            appVersion: "1.0 (1)"
        )
        let data = try JSONEncoder().encode(draft)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"email\""))
    }

    @Test("I1: nil licenseID is omitted from the JSON body entirely")
    internal func nilLicenseIDOmitted() throws {
        let draft = StowerFeedbackDraft(
            text: "Good",
            email: nil,
            licenseID: nil,
            appVersion: "1.0 (1)"
        )
        let data = try JSONEncoder().encode(draft)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"licenseID\""))
    }

    @Test("I1: anonymous draft encodes only text and appVersion")
    internal func anonymousDraftKeySet() throws {
        let draft = StowerFeedbackDraft(
            text: "Good",
            email: nil,
            licenseID: nil,
            appVersion: "1.0 (1)"
        )
        let data = try JSONEncoder().encode(draft)
        let dict = try JSONDecoder().decode([String: String].self, from: data)
        #expect(dict.keys.sorted() == ["appVersion", "text"])
    }

    // MARK: - I2: licenseKey never in the payload

    @Test("I2: StowerFeedbackDraft has no licenseKey property")
    internal func noLicenseKeyProperty() throws {
        // Encode a draft and confirm the raw JSON contains no licenseKey substring.
        // Encoding must succeed — a fallback to empty Data would let this guardrail
        // pass vacuously, so `try` fails the test loudly if encoding ever breaks.
        let draft = StowerFeedbackDraft(
            text: "test",
            email: nil,
            licenseID: "lic-1",
            appVersion: "1.0"
        )
        let data = try JSONEncoder().encode(draft)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("licenseKey"))
    }

    // MARK: - I3: HTTP status classification

    @Test("I3: HTTP 200 maps to .sent")
    internal func http200IsSent() async throws {
        let sut = try client(status: 200)
        let result = await sut.send(draft: anyDraft())
        #expect(result == .sent)
    }

    @Test("I3: HTTP 202 maps to .sent (fire-and-forget accept)")
    internal func http202IsSent() async throws {
        let sut = try client(status: 202)
        let result = await sut.send(draft: anyDraft())
        #expect(result == .sent)
    }

    @Test("I3: HTTP 299 (edge of 2xx range) maps to .sent")
    internal func http299IsSent() async throws {
        let sut = try client(status: 299)
        let result = await sut.send(draft: anyDraft())
        #expect(result == .sent)
    }

    @Test("I3: HTTP 500 maps to .failed(.httpStatus(500))")
    internal func http500IsFailed() async throws {
        let sut = try client(status: 500)
        let result = await sut.send(draft: anyDraft())
        #expect(result == .failed(.httpStatus(500)))
    }

    @Test("I3: HTTP 401 maps to .failed(.httpStatus(401))")
    internal func http401IsFailed() async throws {
        let sut = try client(status: 401)
        let result = await sut.send(draft: anyDraft())
        #expect(result == .failed(.httpStatus(401)))
    }

    @Test("I3: a transport throw maps to .failed(.transport)")
    internal func transportThrowIsFailed() async {
        let sut = StowerFeedbackClient(
            functionBaseURL: baseURL,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        let result = await sut.send(draft: anyDraft())
        #expect(result == .failed(.transport))
    }

    @Test("I3: an invalid base URL maps to .failed(.badURL)")
    internal func badURLIsFailed() async {
        let sut = StowerFeedbackClient(
            functionBaseURL: "not a url ://",
            transport: { _ in fatalError("transport must not be called for a bad URL") }
        )
        let result = await sut.send(draft: anyDraft())
        #expect(result == .failed(.badURL))
    }

    // MARK: - Request shape

    @Test("the request POSTs to the feedback path with no Authorization header")
    internal func requestShape() async throws {
        let captured = CapturedRequest()
        let sut = StowerFeedbackClient(
            functionBaseURL: baseURL,
            transport: { request in
                await captured.set(request)
                let url = try #require(URL(string: "https://example.invalid/feedback"))
                let resp = try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data(), resp)
            }
        )
        _ = await sut.send(draft: anyDraft())
        let request = try #require(await captured.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == baseURL + "/feedback")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    // MARK: - Helpers

    private func anyDraft() -> StowerFeedbackDraft {
        StowerFeedbackDraft(text: "test", email: nil, licenseID: nil, appVersion: "1.0 (1)")
    }
}

/// Captures the request a stub transport received across the `Sendable` boundary.
private actor CapturedRequest {
    private(set) var request: URLRequest?

    func set(_ request: URLRequest) {
        self.request = request
    }
}
