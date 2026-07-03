import Foundation
import Testing

@testable import StowerMacUI

/// The client's outcome classification (I-Success2xxOnly): HTTP 2xx → `.sent`;
/// 4xx/5xx/throw → `.failed` — all driven by a stub transport, never the network.
@Suite internal struct StowerFeedbackClientTests {

    private let submission = StowerFeedbackSubmission(
        message: "hello",
        email: nil,
        instanceID: nil,
        appVersion: "1.0 (1)",
        osVersion: "macOS 15.4",
        licenseStatus: .trial
    )

    /// A client whose transport returns a fixed empty body at `status`.
    private func client(status: Int) throws -> StowerFeedbackClient {
        let url = try #require(URL(string: "https://relay.invalid/feedback"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        return StowerFeedbackClient(
            endpointURL: "https://relay.invalid/feedback",
            transport: { _ in (Data(), response) }
        )
    }

    @Test("I-Success2xxOnly: a 200 classifies as .sent")
    internal func okIsSent() async throws {
        let sut = try client(status: 200)
        #expect(await sut.send(submission) == .sent)
    }

    @Test("I-Success2xxOnly: a 204 classifies as .sent")
    internal func noContentIsSent() async throws {
        let sut = try client(status: 204)
        #expect(await sut.send(submission) == .sent)
    }

    @Test("I-Success2xxOnly: a 400 classifies as .failed")
    internal func badRequestIsFailed() async throws {
        let sut = try client(status: 400)
        #expect(await sut.send(submission) == .failed)
    }

    @Test("I-Success2xxOnly: a 429 (rate limited) classifies as .failed")
    internal func rateLimitedIsFailed() async throws {
        let sut = try client(status: 429)
        #expect(await sut.send(submission) == .failed)
    }

    @Test("I-Success2xxOnly: a 500 classifies as .failed")
    internal func serverErrorIsFailed() async throws {
        let sut = try client(status: 500)
        #expect(await sut.send(submission) == .failed)
    }

    @Test("I-Success2xxOnly: a transport throw classifies as .failed")
    internal func transportThrowIsFailed() async {
        let client = StowerFeedbackClient(
            endpointURL: "https://relay.invalid/feedback",
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        #expect(await client.send(submission) == .failed)
    }

    @Test("a non-HTTP response classifies as .failed")
    internal func nonHTTPResponseIsFailed() async throws {
        let url = try #require(URL(string: "https://relay.invalid/feedback"))
        let client = StowerFeedbackClient(
            endpointURL: "https://relay.invalid/feedback",
            transport: { _ in
                (
                    Data(),
                    URLResponse(
                        url: url,
                        mimeType: nil,
                        expectedContentLength: 0,
                        textEncodingName: nil
                    )
                )
            }
        )
        #expect(await client.send(submission) == .failed)
    }

    @Test("an unparseable endpoint classifies as .failed without a network call")
    internal func badEndpointIsFailed() async throws {
        let called = StowerTransportCalled()
        let client = StowerFeedbackClient(
            endpointURL: "",
            transport: { _ in
                await called.markCalled()
                throw URLError(.badURL)
            }
        )
        #expect(await client.send(submission) == .failed)
        #expect(await called.wasCalled == false)
    }

    @Test("the request is a JSON POST carrying the encoded submission body")
    internal func requestIsJSONPost() async throws {
        let captured = StowerCapturedFeedbackRequest()
        let url = try #require(URL(string: "https://relay.invalid/feedback"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        let client = StowerFeedbackClient(
            endpointURL: "https://relay.invalid/feedback",
            transport: { request in
                await captured.set(request)
                return (Data(), response)
            }
        )

        _ = await client.send(submission)

        let request = try #require(await captured.request)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval < 60)
        let body = try #require(request.httpBody)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["message"] as? String == "hello")
    }
}

/// Captures the request a stub transport received, across the `Sendable` boundary.
private actor StowerCapturedFeedbackRequest {
    private(set) var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}

/// Records whether a stub transport was invoked, across the `Sendable` boundary.
private actor StowerTransportCalled {
    private(set) var wasCalled = false
    func markCalled() { wasCalled = true }
}
