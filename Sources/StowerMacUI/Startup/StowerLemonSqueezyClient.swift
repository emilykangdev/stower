import Foundation

/// Posts to Lemon Squeezy's public `/v1/licenses/activate` — the app's ONLY
/// network egress in v1, made once at first-run activation.
///
/// `/activate` needs no API key: it verifies the key, enforces the 5-device
/// `activation_limit` server-side, and returns `instance.id`. The response is
/// decoded into a MINIMAL shape — the verdict, the `instance.id`, and the
/// product-identity ints (`meta.store_id` / `meta.product_id`) — so the
/// `meta.customer_email` / `customer_name` Lemon Squeezy also returns are never
/// decoded, retained, or logged. This client makes no other call (no `/validate`
/// in v1).
///
/// The `/activate` endpoint is global: a valid license key for ANY Lemon Squeezy
/// store/product returns `activated:true`. So the client requires the response's
/// `store_id` + `product_id` to equal Stower's configured IDs before returning
/// `.activated` — otherwise another product's key would unlock Stower (the Lemon
/// Squeezy license-keys guide calls this out). A mismatch is `.invalid`.
internal struct StowerLemonSqueezyClient: Sendable {
    /// Runs one request; injectable so tests need no network.
    internal typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport
    private let expectedStoreID: Int
    private let expectedProductID: Int

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - expectedStoreID: Stower's Lemon Squeezy `store_id`; the response must match.
    ///   - expectedProductID: Stower's Lemon Squeezy `product_id`; the response must match.
    ///   - transport: The request runner; defaults to `URLSession.shared`.
    internal init(
        expectedStoreID: Int,
        expectedProductID: Int,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.expectedStoreID = expectedStoreID
        self.expectedProductID = expectedProductID
        self.transport = transport
    }

    /// Activates `key`, classifying the outcome.
    ///
    /// A transport throw, a 5xx, or an undecodable body is `.couldNotReach`
    /// (recoverable; also the offline first-run case); `activated:true` with an
    /// `instance.id` AND a `meta` `store_id`/`product_id` matching Stower's is
    /// `.activated`; anything else (`activated:false`, or a key for another
    /// store/product) is `.invalid`.
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
        guard body.activated, let instanceID = body.instance?.id else {
            return .invalid
        }
        // A key for another Lemon Squeezy product/store also returns activated:true,
        // so it must match Stower's own product before it grants access.
        guard body.meta?.storeID == expectedStoreID, body.meta?.productID == expectedProductID
        else {
            return .invalid
        }
        return .activated(instanceID: instanceID)
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

/// The minimal decode of the activate response: the verdict, the bound instance
/// id, and the product-identity `meta` used to confirm the key is Stower's.
private struct StowerActivateBody: Decodable {
    let activated: Bool
    let instance: Instance?
    let meta: StowerActivateMeta?

    struct Instance: Decodable {
        let id: String
    }
}

/// The product-identity slice of the activate response `meta`.
///
/// Only `store_id` / `product_id` are decoded — never `customer_email` /
/// `customer_name`, which have no field here, so a wide decode can't leak PII.
private struct StowerActivateMeta: Decodable {
    let storeID: Int?
    let productID: Int?

    enum CodingKeys: String, CodingKey {
        case storeID = "store_id"
        case productID = "product_id"
    }
}
