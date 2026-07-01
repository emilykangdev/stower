import Foundation

/// The coarse, PII-safe reason a feedback submission failed.
///
/// Carries no URL, no body text, and no user data — only a structural cause the
/// sheet can use for retryable error copy. Separate from
/// `StowerLicenseUnreachableReason` to keep licensing semantics out of feedback
/// error copy and analytics (JC6).
internal enum StowerFeedbackFailure: Sendable, Equatable {
    /// The `feedbackBaseURL` from config is not a valid `URL`.
    case badURL

    /// JSON encoding of the draft failed.
    case encodeFailure

    /// A transport-level throw (network, timeout, TLS, etc.).
    case transport

    /// The server replied with a non-2xx HTTP status; carries the code.
    case httpStatus(Int)
}

/// The result of one feedback submission attempt.
internal enum StowerFeedbackResult: Sendable, Equatable {
    /// The server accepted the submission (any 2xx status).
    case sent

    /// The submission could not be delivered; carries the coarse cause.
    case failed(StowerFeedbackFailure)
}

/// The JSON body the client POSTs to `…/functions/v1/feedback`.
///
/// `email` and `licenseID` are omitted entirely from the JSON when nil — never
/// emitted as `null` or as an empty string. The hand-written `encode(to:)` makes
/// this explicit and keeps `licenseKey` structurally unreachable.
internal struct StowerFeedbackDraft: Sendable, Encodable {
    /// The user's free-text feedback (never blank — guarded by the form model).
    internal let text: String

    /// The user's optional reply email, nil when the field was left empty.
    ///
    /// The caller passes `nil` (not an empty string) when the user left it blank
    /// so the JSON body cleanly omits the field rather than sending `email: ""`.
    internal let email: String?

    /// The Keygen license resource id, nil when no lease exists (A4).
    ///
    /// `licenseKey` (the secret) is intentionally absent from this type.
    internal let licenseID: String?

    /// The human-readable app version string, e.g. `"1.0 (42)"`.
    internal let appVersion: String

    /// Encodes only the non-nil, non-secret fields.
    ///
    /// `email` and `licenseID` are omitted when nil; `licenseKey` is structurally
    /// absent from the type and therefore cannot appear in the encoded output.
    internal func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(licenseID, forKey: .licenseID)
        try container.encodeIfPresent(email, forKey: .email)
    }

    private enum CodingKeys: String, CodingKey {
        case text, appVersion, licenseID, email
    }
}

/// POSTs a `StowerFeedbackDraft` to the Supabase `feedback` edge function.
///
/// Modeled on `StowerTrialMintClient`: injectable `Transport` typealias, a
/// `functionBaseURL`, header-less JSON POST (no `Authorization` — the function
/// is deployed `--no-verify-jwt`), and a 2xx-wide accept range (A2). The client
/// holds no process globals — `licenseID`, `appVersion`, and the base URL are
/// all injected so the type is unit-testable with no bundle or config access.
internal struct StowerFeedbackClient: Sendable {
    /// Runs one request; injectable so tests need no network.
    internal typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let functionBaseURL: String
    private let transport: Transport

    /// Creates a feedback client.
    ///
    /// - Parameters:
    ///   - functionBaseURL: The Supabase function base URL (e.g. `…/functions/v1`,
    ///     no trailing slash); `send(draft:)` appends `/feedback`.
    ///   - transport: The request runner; defaults to `URLSession.shared`.
    internal init(
        functionBaseURL: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.functionBaseURL = functionBaseURL
        self.transport = transport
    }

    /// Submits `draft` and returns `.sent` on any 2xx, `.failed(reason)` otherwise.
    ///
    /// Fires and forgets delivery: the function forwards via Resend server-side;
    /// the app only needs the accept acknowledgement. Cancel-safe — if the task is
    /// cancelled the transport throws `URLError(.cancelled)`, which maps to
    /// `.failed(.transport)`.
    internal func send(draft: StowerFeedbackDraft) async -> StowerFeedbackResult {
        guard let request = feedbackRequest(draft: draft) else {
            return .failed(.badURL)
        }
        let response: URLResponse
        do {
            (_, response) = try await transport(request)
        } catch {
            return .failed(.transport)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return Self.successRange.contains(status) ? .sent : .failed(.httpStatus(status))
    }

    /// Builds the JSON POST to `…/feedback`, or `nil` if the URL won't parse or
    /// encoding fails.
    private func feedbackRequest(draft: StowerFeedbackDraft) -> URLRequest? {
        guard let url = URL(string: functionBaseURL + Self.feedbackPath) else {
            return nil
        }
        guard let body = try? JSONEncoder().encode(draft) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private static let feedbackPath = "/feedback"
    private static let requestTimeout: TimeInterval = 15
    private static let successRange = 200...299
}
