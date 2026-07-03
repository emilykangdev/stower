import Foundation

/// POSTs a `StowerFeedbackSubmission` as JSON to the Deno relay — the feature's
/// only network egress.
///
/// Mirrors `StowerLemonSqueezyClient`: a `Sendable` struct with an injectable
/// `Transport`, a guard-let request build (never a force-unwrap on the endpoint
/// or the encoder), a short timeout, and a 2xx→`.sent` classification. A bad
/// endpoint, a transport throw, or any non-2xx fails closed as `.failed`, so a
/// misconfigured URL never crashes and never reads as false success
/// (I-Success2xxOnly).
internal struct StowerFeedbackClient: Sendable {
    /// Runs one request; injectable so tests need no network.
    internal typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let endpointURL: String
    private let transport: Transport

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - endpointURL: The Deno relay URL (from `StowerFeedbackConfig.resolved`).
    ///   - transport: The request runner; defaults to `URLSession.shared`.
    internal init(
        endpointURL: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.endpointURL = endpointURL
        self.transport = transport
    }

    /// Sends `submission`, classifying the outcome.
    ///
    /// A bad endpoint URL, an encode failure, or a transport throw is `.failed`;
    /// an HTTP 2xx is `.sent`; any other status is `.failed`.
    ///
    /// - Parameter submission: The feedback payload.
    /// - Returns: `.sent` on HTTP 2xx, else `.failed`.
    internal func send(_ submission: StowerFeedbackSubmission) async -> StowerFeedbackSendResult {
        guard let request = Self.sendRequest(endpointURL: endpointURL, submission: submission)
        else {
            return .failed
        }
        let response: URLResponse
        do {
            (_, response) = try await transport(request)
        } catch {
            return .failed
        }
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        return Self.successStatusCodes.contains(statusCode) ? .sent : .failed
    }

    /// Builds the JSON POST, or `nil` if the endpoint fails to parse or the
    /// payload fails to encode — treated as `.failed` rather than force-unwrapped.
    private static func sendRequest(
        endpointURL: String,
        submission: StowerFeedbackSubmission
    ) -> URLRequest? {
        guard let url = URL(string: endpointURL) else { return nil }
        guard let body = try? JSONEncoder().encode(submission) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// The HTTP status range treated as delivery success.
    private static let successStatusCodes = 200...299

    /// A short timeout so an offline/blackholed send fails fast, not after
    /// URLSession's ~60s default.
    private static let requestTimeout: TimeInterval = 15
}
