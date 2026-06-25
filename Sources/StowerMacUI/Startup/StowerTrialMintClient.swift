import Foundation

/// The outcome of one Supabase `mint-trial` round-trip.
///
/// There is deliberately no `{null, null}` success: a 200 that fails to decode
/// both fields is `.unreachable`, never a half-minted license.
internal enum StowerTrialMint: Sendable, Equatable {
    /// The server returned this device's trial license.
    case minted(key: String, licenseID: String)

    /// A mint is in flight for this fingerprint (a winner is mid-mint, or a
    /// crashed claim is still inside the reclaim window) — retry shortly.
    case retryShortly

    /// Transport throw / 5xx / undecodable body — the server could not be reached
    /// for a verdict.
    case unreachable
}

/// POSTs a device `fingerprint` to the Supabase `mint-trial` route and classifies
/// the reply.
///
/// Carries only the fingerprint hash — never the raw UUID, never a key.
internal struct StowerTrialMintClient: Sendable {
    /// Runs one request; injectable so tests need no network.
    internal typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let functionBaseURL: String
    private let transport: Transport

    /// Creates a mint client.
    ///
    /// - Parameters:
    ///   - functionBaseURL: The Supabase function base, e.g.
    ///     `https://<ref>.supabase.co/functions/v1/license`; `/mint-trial` is
    ///     appended.
    ///   - transport: The request runner; defaults to `URLSession.shared`.
    internal init(
        functionBaseURL: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.functionBaseURL = functionBaseURL
        self.transport = transport
    }

    /// Mints (or returns the existing) trial license for `fingerprint`.
    ///
    /// - Returns: `.minted` with the key + license id on a 200; `.retryShortly`
    ///   on the server's transient retry status; `.unreachable` on a transport
    ///   throw, any other status, or an undecodable 200.
    internal func mint(fingerprint: String) async -> StowerTrialMint {
        guard let request = mintRequest(fingerprint: fingerprint) else { return .unreachable }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == Self.retryStatus { return .retryShortly }
        guard status == Self.okStatus,
            let body = try? JSONDecoder().decode(StowerMintResponse.self, from: data),
            let key = body.key, let licenseID = body.licenseID,
            !key.isEmpty, !licenseID.isEmpty
        else {
            return .unreachable
        }
        return .minted(key: key, licenseID: licenseID)
    }

    /// Builds the JSON POST to `…/mint-trial`, or `nil` if the URL won't parse.
    private func mintRequest(fingerprint: String) -> URLRequest? {
        guard let url = URL(string: functionBaseURL + Self.mintPath),
            let body = try? JSONEncoder().encode(StowerMintRequest(fingerprint: fingerprint))
        else {
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

    private static let mintPath = "/mint-trial"
    private static let requestTimeout: TimeInterval = 15
    private static let okStatus = 200
    private static let retryStatus = 503
}

/// The mint request body: only the fingerprint hash.
private struct StowerMintRequest: Encodable {
    let fingerprint: String
}

/// The mint response: the license key + resource id, each optional so a partial
/// body decodes to `.unreachable` rather than a half-minted license.
private struct StowerMintResponse: Decodable {
    let key: String?
    let licenseID: String?
}
