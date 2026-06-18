import Foundation

/// Posts to Lemon Squeezy's public `/v1/licenses/activate` — the app's ONLY
/// network egress in v1, made once at first-run activation.
///
/// `/activate` needs no API key: it verifies the key, enforces the 5-device
/// `activation_limit` server-side, and returns `instance.id`. The response is
/// decoded into a MINIMAL `{activated, instance.id}` shape, so the
/// `meta.customer_email` Lemon Squeezy also returns is never decoded, retained,
/// or logged. This client makes no other call — there is no `/validate` in v1.
internal struct StowerLemonSqueezyClient: Sendable {
    /// Runs one request; injectable so tests need no network.
    internal typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    /// Creates a client.
    ///
    /// - Parameter transport: The request runner; defaults to `URLSession.shared`.
    internal init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.transport = transport
    }

    /// Activates `key`, classifying the outcome.
    ///
    /// A transport throw, a 5xx, or an undecodable body is `.couldNotReach`
    /// (recoverable; also the offline first-run case); a decoded `activated:true`
    /// with an `instance.id` is `.activated`; a decoded `activated:false` is
    /// `.invalid`.
    ///
    /// - Parameters:
    ///   - key: The trimmed license key.
    ///   - instanceName: The device label sent as `instance_name`.
    /// - Returns: `.activated`, `.invalid`, or `.couldNotReach` per the rules above.
    internal func activate(key: String, instanceName: String) async -> StowerLicenseActivation {
        guard let request = Self.activateRequest(key: key, instanceName: instanceName) else {
            return .couldNotReach
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .couldNotReach
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        if let statusCode, Self.serverErrorStatusCodes.contains(statusCode) {
            return .couldNotReach
        }
        guard let body = try? JSONDecoder().decode(StowerActivateBody.self, from: data) else {
            return .couldNotReach
        }
        if body.activated, let instanceID = body.instance?.id {
            return .activated(instanceID: instanceID)
        }
        return .invalid
    }

    /// Builds the percent-encoded form POST, or `nil` if the (constant) endpoint
    /// fails to parse — treated as `.couldNotReach` rather than force-unwrapped.
    private static func activateRequest(key: String, instanceName: String) -> URLRequest? {
        guard let url = URL(string: activateURLString) else { return nil }
        var request = URLRequest(url: url)
        // A short timeout so a first-run user on a blackholed network gets
        // `.couldNotReach` in seconds, not URLSession's ~60s default.
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody([
            URLQueryItem(name: "license_key", value: key),
            URLQueryItem(name: "instance_name", value: instanceName)
        ])
        return request
    }

    /// Percent-encodes each field to RFC 3986 unreserved characters only — so a
    /// `+`, `&`, `%`, space, or newline in a pasted key or a device name can't
    /// corrupt or rewrite a field — then lets `URLComponents` join them.
    ///
    /// (`URLComponents.queryItems` alone leaves `+` literal, which a form decoder
    /// reads as a space; pre-encoding to unreserved-only closes that.)
    private static func formBody(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.percentEncodedQueryItems = items.map { item in
            URLQueryItem(
                name: item.name.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? "",
                value: (item.value ?? "").addingPercentEncoding(withAllowedCharacters: formAllowed)
            )
        }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    /// RFC 3986 unreserved set: everything else in a field is percent-encoded.
    private static let formAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static let serverErrorStatusCodes = 500...599
    private static let requestTimeout: TimeInterval = 15
    private static let activateURLString = "https://api.lemonsqueezy.com/v1/licenses/activate"
}

/// The minimal decode of the activate response: only the verdict and the bound
/// instance id.
///
/// Deliberately has no field for `meta.customer_email` / other PII, so a wide
/// decode can't leak it (compiler-enforced shape).
private struct StowerActivateBody: Decodable {
    let activated: Bool
    let instance: Instance?

    struct Instance: Decodable {
        let id: String
    }
}
