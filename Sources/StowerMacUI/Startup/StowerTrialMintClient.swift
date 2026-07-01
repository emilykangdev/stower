import Foundation

/// The outcome of one Supabase `mint-trial` round-trip.
///
/// There is deliberately no partial success: a 200 that fails to decode every
/// required field is `.unreachable`, never a half-minted license. The signed
/// `machineFile` is required so first run has offline authority (contract §5b).
internal enum StowerTrialMint: Sendable, Equatable {
    /// The server returned this device's trial license, with the secret key, the
    /// resource id, and the signed machine file for offline authority.
    case minted(licenseKey: String, licenseID: String, machineFile: String)

    /// A mint is in flight for this fingerprint (a winner is mid-mint, or a
    /// crashed claim is still inside the reclaim window) — retry shortly.
    case retryShortly

    /// Transport throw / any non-success HTTP status / undecodable body — the
    /// server could not produce a verdict; carries the coarse PII-safe cause.
    case unreachable(StowerLicenseUnreachableReason)
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
    /// - Returns: `.minted` with the secret key, license id, and signed machine
    ///   file on a 200; `.retryShortly` on the server's transient retry status;
    ///   `.unreachable` on a transport throw, any other status, or a 200 missing
    ///   any required field.
    internal func mint(fingerprint: String) async -> StowerTrialMint {
        guard let request = mintRequest(fingerprint: fingerprint) else {
            return .unreachable(.badURL)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .unreachable(.transport)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == Self.retryStatus { return .retryShortly }
        guard status == Self.okStatus else { return .unreachable(.httpStatus(status)) }
        guard let body = try? JSONDecoder().decode(StowerMintResponse.self, from: data),
            let licenseKey = body.licenseKey, let licenseID = body.licenseID,
            let machineFile = body.machineFile,
            !licenseKey.isEmpty, !licenseID.isEmpty, !machineFile.isEmpty
        else {
            return .unreachable(.decodeFailure)
        }
        return .minted(licenseKey: licenseKey, licenseID: licenseID, machineFile: machineFile)
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

/// The mint response (`{minted, licenseKey, licenseID, machineID, machineFile}`).
///
/// The renamed `licenseKey` (was `key`), the resource id, and the signed machine
/// file. Each is optional so a partial body decodes to `.unreachable` rather than
/// a half-minted license. `minted`/`machineID` are on the wire but unused by the
/// app — only the three fields the lease stores are decoded.
private struct StowerMintResponse: Decodable {
    let licenseKey: String?
    let licenseID: String?
    let machineFile: String?
}
