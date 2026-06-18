import Foundation

/// The verdict of a Keygen machine **activate**.
internal enum StowerKeygenActivation: Sendable, Equatable {
    /// The machine was bound to the license; carries the machine resource id.
    case activated(machineID: String)

    /// The license's `maxMachines` is already reached — no new activation.
    case limitReached
}

/// The verdict of a Keygen license **validate-key**.
internal enum StowerKeygenValidation: Sendable, Equatable {
    /// The license is valid for the supplied fingerprint scope.
    case valid

    /// The license is not valid; carries Keygen's machine-readable reason code.
    case invalid(code: String)
}

/// A Keygen call that reached the server but could not yield a verdict.
///
/// A transport-layer throw (offline, DNS, TLS) is NOT mapped here — it propagates
/// out of the client so the caller can distinguish "unreachable" from "reached".
internal enum StowerKeygenError: Error, Sendable, Equatable {
    /// A 5xx (or other unhandled status) — retryable.
    case server(status: Int)

    /// A 2xx whose body lacked the expected field.
    case malformedResponse
}

/// Raw `URLSession` REST client for `api.keygen.sh`: machine **activate**,
/// machine-file **check-out**, and license **validate-key**.
///
/// Keygen ships no Swift SDK, so this is hand-rolled JSON:API with a minimal
/// `Decodable` surface. License creation needs the admin secret and lives in the
/// Supabase function — never here; this client uses only the license-scoped
/// `Authorization: License <key>` (activate/check-out) or the unauthenticated
/// validate-key call. The license key never reaches a log (precheck 6g bans
/// logging in this module).
internal struct StowerKeygenClient: Sendable {
    /// Runs one request; injectable so tests need no network.
    internal typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let account: String
    private let transport: Transport

    /// Creates a client for the Keygen `account`.
    ///
    /// - Parameters:
    ///   - account: The Keygen account id/slug embedded in every path.
    ///   - transport: The request runner; defaults to `URLSession.shared`.
    internal init(
        account: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.account = account
        self.transport = transport
    }

    /// Activates a machine for `licenseID`, bound to `fingerprint`.
    ///
    /// - Returns: `.activated` with the machine id, or `.limitReached` when the
    ///   license already holds its max machines.
    /// - Throws: `StowerKeygenError` on a 5xx/malformed body; the transport's own
    ///   error on an unreachable network.
    internal func activate(
        licenseKey: String,
        licenseID: String,
        fingerprint: String
    ) async throws -> StowerKeygenActivation {
        let body = StowerActivateRequest(
            data: .init(
                attributes: .init(fingerprint: fingerprint),
                relationships: .init(license: .init(data: .init(id: licenseID)))
            )
        )
        let request = try licensedRequest(path: machinesPath, licenseKey: licenseKey, body: body)
        let (data, response) = try await transport(request)
        let status = Self.statusCode(of: response)
        if Self.successRange.contains(status) {
            guard let id = Self.decode(StowerDataIDResponse.self, from: data)?.data.id else {
                throw StowerKeygenError.malformedResponse
            }
            return .activated(machineID: id)
        }
        if status == Self.machineLimitStatus { return .limitReached }
        throw StowerKeygenError.server(status: status)
    }

    /// Checks out a signed machine-file for `machineID` (TTL = ``machineFileTTL``).
    ///
    /// - Returns: the PEM-enveloped machine-file certificate.
    /// - Throws: `StowerKeygenError` on a non-2xx/malformed body; the transport's
    ///   own error when unreachable.
    internal func checkOutMachineFile(
        machineID: String,
        licenseKey: String
    ) async throws -> String {
        let request = try checkOutRequest(machineID: machineID, licenseKey: licenseKey)
        let (data, response) = try await transport(request)
        guard Self.successRange.contains(Self.statusCode(of: response)) else {
            throw StowerKeygenError.server(status: Self.statusCode(of: response))
        }
        guard
            let certificate = Self.decode(StowerCheckoutResponse.self, from: data)?
                .data.attributes.certificate
        else {
            throw StowerKeygenError.malformedResponse
        }
        return certificate
    }

    /// Validates `licenseKey` for `fingerprint` (the unauthenticated validate-key
    /// scope check).
    ///
    /// - Returns: `.valid`, or `.invalid` with Keygen's reason code.
    /// - Throws: `StowerKeygenError` on a non-2xx/malformed body; the transport's
    ///   own error when unreachable.
    internal func validate(
        licenseKey: String,
        fingerprint: String
    ) async throws -> StowerKeygenValidation {
        let body = StowerValidateRequest(
            meta: .init(key: licenseKey, scope: .init(fingerprint: fingerprint))
        )
        let request = try jsonAPIRequest(path: validateKeyPath, body: body)
        let (data, response) = try await transport(request)
        guard Self.successRange.contains(Self.statusCode(of: response)) else {
            throw StowerKeygenError.server(status: Self.statusCode(of: response))
        }
        guard let meta = Self.decode(StowerValidateResponse.self, from: data)?.meta else {
            throw StowerKeygenError.malformedResponse
        }
        return meta.valid ? .valid : .invalid(code: meta.code ?? Self.unknownValidationCode)
    }

    /// Builds a JSON:API POST and adds the license-scoped `Authorization` header.
    private func licensedRequest(
        path: String,
        licenseKey: String,
        body: some Encodable
    ) throws -> URLRequest {
        var request = try jsonAPIRequest(path: path, body: body)
        request.setValue("License \(licenseKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds a JSON:API POST to `path` carrying `body`.
    private func jsonAPIRequest(path: String, body: some Encodable) throws -> URLRequest {
        guard let url = URL(string: Self.baseURL + path) else {
            throw StowerKeygenError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.contentType, forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Builds the check-out POST with the `ttl` query and license `Authorization`.
    private func checkOutRequest(machineID: String, licenseKey: String) throws -> URLRequest {
        guard
            var components = URLComponents(
                string: Self.baseURL + checkOutPath(machineID: machineID)
            )
        else {
            throw StowerKeygenError.malformedResponse
        }
        components.queryItems = [URLQueryItem(name: "ttl", value: String(Self.checkOutTTLSeconds))]
        guard let url = components.url else { throw StowerKeygenError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.contentType, forHTTPHeaderField: "Accept")
        request.setValue("License \(licenseKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private var machinesPath: String { "/v1/accounts/\(account)/machines" }
    private var validateKeyPath: String { "/v1/accounts/\(account)/licenses/actions/validate-key" }
    private func checkOutPath(machineID: String) -> String {
        "/v1/accounts/\(account)/machines/\(machineID)/actions/check-out"
    }

    private static func statusCode(of response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    /// The check-out TTL, in seconds, derived from ``machineFileTTL``.
    private static var checkOutTTLSeconds: Int64 { machineFileTTL.components.seconds }

    /// The offline-validity window a checked-out machine-file is granted.
    ///
    /// Keygen requires at least one hour; this is the single source the gate
    /// (Plan B) reads as the grace boundary — the file's own expiry is the
    /// boundary, so the gate must not add a second window on top of it.
    internal static let machineFileTTL: Duration = .seconds(7 * 24 * 60 * 60)

    private static let baseURL = "https://api.keygen.sh"
    private static let contentType = "application/vnd.api+json"
    private static let requestTimeout: TimeInterval = 15
    private static let successRange = 200...299
    private static let machineLimitStatus = 422
    private static let unknownValidationCode = "UNKNOWN"
}

/// The activate request body (JSON:API): a machine bound to a license, with the
/// device fingerprint as the machine fingerprint.
private struct StowerActivateRequest: Encodable {
    let data: Resource

    struct Resource: Encodable {
        let type = "machines"
        let attributes: Attributes
        let relationships: Relationships
    }

    struct Attributes: Encodable {
        let fingerprint: String
    }

    struct Relationships: Encodable {
        let license: LicenseRelationship
    }

    struct LicenseRelationship: Encodable {
        let data: LicenseResource
    }

    struct LicenseResource: Encodable {
        let type = "licenses"
        let id: String
    }
}

/// The validate-key request body: the key plus a fingerprint scope.
private struct StowerValidateRequest: Encodable {
    let meta: Meta

    struct Meta: Encodable {
        let key: String
        let scope: Scope
    }

    struct Scope: Encodable {
        let fingerprint: String
    }
}

/// A JSON:API response carrying only `data.id` (activate's machine id).
private struct StowerDataIDResponse: Decodable {
    let data: Resource

    struct Resource: Decodable {
        let id: String
    }
}

/// The check-out response: the machine-file certificate in `data.attributes`.
private struct StowerCheckoutResponse: Decodable {
    let data: Resource

    struct Resource: Decodable {
        let attributes: CertificateAttributes
    }

    struct CertificateAttributes: Decodable {
        let certificate: String
    }
}

/// The validate-key response: the verdict in `meta`.
private struct StowerValidateResponse: Decodable {
    let meta: Meta

    struct Meta: Decodable {
        let valid: Bool
        let code: String?
    }
}
