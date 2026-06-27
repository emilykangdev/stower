import Foundation

/// The typed outcome of one `/check-in` round-trip, mapping the Edge Function's
/// §5 status table to the cases `StowerLicenseGate` routes on.
///
/// HTTP status is authoritative: `401/404/409/503` map by code; a `200` is
/// branched by its `status` verb. An undecodable or field-missing reply is
/// `.unreachable` (transient), never a false verdict.
internal enum StowerCheckInResult: Sendable, Equatable {
    /// `200 ok` — carries the freshly checked-out signed machine file (I13).
    case ok(machineFile: String)

    /// `200 expired` — the trial clock ran out; carries the license id for the paywall.
    case trialExpired(licenseID: String)

    /// `200 wrong_version` — valid license, missing this build's entitlement; carries the id.
    case wrongVersion(licenseID: String)

    /// `404 unknown_license` — the server has no row for this license id (JC6 self-heal).
    case unknownLicense

    /// `401 bad_signature` — treated as transient; the next launch retries.
    case badSignature

    /// `409 fingerprint_mismatch` — the device changed (PAR-36 owns the real UX).
    case fingerprintMismatch

    /// `503` / transport throw / undecodable — the server could not be reached.
    case unreachable
}

/// The online licensing seam `StowerLicenseGate` depends on: trial mint plus
/// JC5-signed reachable check-in.
///
/// A protocol so gate tests inject a spy without a network;
/// `StowerLicenseCheckInClient` is the production conformer.
internal protocol StowerLicenseCheckInProviding: Sendable {
    /// Mints (or returns the existing) trial license for `fingerprint`.
    func mint(fingerprint: String) async -> StowerTrialMint

    /// Sends a JC5-signed `/check-in` for `licenseID`, signing with `licenseKey`.
    func checkIn(
        licenseID: String,
        fingerprint: String,
        licenseKey: String
    ) async -> StowerCheckInResult
}

/// The only online licensing client the Mac app uses: trial mint (delegated to
/// the `StowerTrialMintClient` base, never forked), JC5-signed `/check-in`, and a
/// pure Lemon Squeezy checkout-URL builder for Buy.
///
/// It never calls Keygen or Supabase directly and invents no Edge Function
/// checkout route — the only network egress is `…/license/{mint-trial,check-in}`,
/// and the only Lemon Squeezy surface is the product checkout URL.
internal struct StowerLicenseCheckInClient: StowerLicenseCheckInProviding {
    /// Runs one request; injectable so tests need no network.
    internal typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let mintClient: StowerTrialMintClient
    private let functionBaseURL: String
    private let transport: Transport
    private let signer: StowerCheckInSignature
    private let timestamp: @Sendable () -> String
    private let nonce: @Sendable () -> String

    /// Creates a check-in client.
    ///
    /// - Parameters:
    ///   - functionBaseURL: The Supabase function base, e.g.
    ///     `https://<ref>.supabase.co/functions/v1/license`; `/check-in` is appended.
    ///   - transport: The request runner; defaults to `URLSession.shared`. Shared
    ///     with the composed mint client so both routes use one transport.
    ///   - signer: The JC5 signer; defaults to a fresh instance.
    ///   - timestamp: Supplies the unix-seconds string per request; injectable so
    ///     tests are deterministic. Defaults to `now`.
    ///   - nonce: Supplies a fresh per-request nonce; injectable for tests.
    ///     Defaults to a random UUID hex.
    internal init(
        functionBaseURL: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        signer: StowerCheckInSignature = StowerCheckInSignature(),
        timestamp: @escaping @Sendable () -> String = {
            String(Int(Date().timeIntervalSince1970))
        },
        nonce: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    ) {
        self.mintClient = StowerTrialMintClient(
            functionBaseURL: functionBaseURL,
            transport: transport
        )
        self.functionBaseURL = functionBaseURL
        self.transport = transport
        self.signer = signer
        self.timestamp = timestamp
        self.nonce = nonce
    }

    internal func mint(fingerprint: String) async -> StowerTrialMint {
        await mintClient.mint(fingerprint: fingerprint)
    }

    internal func checkIn(
        licenseID: String,
        fingerprint: String,
        licenseKey: String
    ) async -> StowerCheckInResult {
        guard let url = URL(string: functionBaseURL + Self.checkInPath),
            let body = try? JSONEncoder().encode(
                StowerCheckInRequest(licenseID: licenseID, fingerprint: fingerprint)
            )
        else {
            return .unreachable
        }
        let headers = signer.sign(
            method: Self.postMethod,
            timestamp: timestamp(),
            nonce: nonce(),
            body: body,
            key: licenseKey
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(
                checkInRequest(url: url, body: body, headers: headers)
            )
        } catch {
            return .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return Self.map(status: status, data: data)
    }

    /// Builds the percent-encoded LS product checkout URL carrying the existing
    /// `licenseID` as `checkout[custom][license_id]`, so the `order_created`
    /// webhook's `meta.custom_data.license_id` matches `handleWebhook`.
    ///
    /// Pure and static — Buy is navigation, not a licensing call, so it needs no
    /// client instance. The bracket keys are percent-encoded (the LS backend
    /// decodes them), keeping the result a valid URL.
    internal static func checkoutURL(licenseID: String) -> URL? {
        guard var components = URLComponents(string: checkoutBaseURLString) else { return nil }
        let encodedID =
            licenseID.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? licenseID
        components.percentEncodedQuery = customLicenseIDQueryPrefix + encodedID
        return components.url
    }

    /// Builds the signed JSON `/check-in` POST.
    private func checkInRequest(
        url: URL,
        body: Data,
        headers: StowerCheckInSignature.Headers
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = Self.postMethod
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.jsonContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.jsonContentType, forHTTPHeaderField: "Accept")
        request.setValue(
            headers.timestamp,
            forHTTPHeaderField: StowerCheckInSignature.timestampHeader
        )
        request.setValue(headers.nonce, forHTTPHeaderField: StowerCheckInSignature.nonceHeader)
        request.setValue(
            headers.signature,
            forHTTPHeaderField: StowerCheckInSignature.signatureHeader
        )
        request.httpBody = body
        return request
    }

    /// Maps the HTTP status + `status` verb to a typed result (the §5 table).
    private static func map(status: Int, data: Data) -> StowerCheckInResult {
        let body = try? JSONDecoder().decode(StowerCheckInResponse.self, from: data)
        switch status {
        case okStatus:
            return mapOk(body)
        case badSignatureStatus:
            return .badSignature
        case unknownLicenseStatus:
            return .unknownLicense
        case fingerprintMismatchStatus:
            return .fingerprintMismatch
        default:
            return .unreachable
        }
    }

    /// Maps a `200` reply by its `status` verb; an id/file-missing body is transient.
    private static func mapOk(_ body: StowerCheckInResponse?) -> StowerCheckInResult {
        switch body?.status {
        case okVerb:
            guard let machineFile = body?.machineFile, !machineFile.isEmpty else {
                return .unreachable
            }
            return .ok(machineFile: machineFile)
        case expiredVerb:
            guard let id = body?.licenseID, !id.isEmpty else { return .unreachable }
            return .trialExpired(licenseID: id)
        case wrongVersionVerb:
            guard let id = body?.licenseID, !id.isEmpty else { return .unreachable }
            return .wrongVersion(licenseID: id)
        default:
            return .unreachable
        }
    }

    private static let checkInPath = "/check-in"
    private static let postMethod = "POST"
    private static let jsonContentType = "application/json"
    private static let requestTimeout: TimeInterval = 15
    private static let okStatus = 200
    private static let badSignatureStatus = 401
    private static let unknownLicenseStatus = 404
    private static let fingerprintMismatchStatus = 409
    private static let okVerb = "ok"
    private static let expiredVerb = "expired"
    private static let wrongVersionVerb = "wrong_version"

    /// The Lemon Squeezy product checkout URL — the only surviving LS literal.
    private static let checkoutBaseURLString = "https://stower.lemonsqueezy.com/checkout"
    /// The percent-encoded `checkout[custom][license_id]=` query prefix.
    private static let customLicenseIDQueryPrefix = "checkout%5Bcustom%5D%5Blicense_id%5D="
}

/// The check-in request body: the license id + the device fingerprint hash.
private struct StowerCheckInRequest: Encodable {
    let licenseID: String
    let fingerprint: String
}

/// The minimal decode of a `/check-in` reply.
///
/// `status` is the verb; `licenseID` and `machineFile` are present only on the
/// statuses that carry them. The key is NEVER on the wire (I17), so there is no
/// field to decode it into.
private struct StowerCheckInResponse: Decodable {
    let status: String?
    let licenseID: String?
    let machineFile: String?
}
