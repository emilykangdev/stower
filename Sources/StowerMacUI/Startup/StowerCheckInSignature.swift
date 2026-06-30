import CryptoKit
import Foundation

/// The per-license check-in request signature (JC5): a pure value type that
/// reproduces the Edge Function's `requestSignature.ts` verifier byte-for-byte.
///
/// Check-in carries its auth in three `X-Stower-*` HTTP headers, NOT the body — a
/// body-embedded signature is circular (the body can't be re-serialized
/// canonically to re-hash it). The signed message commits to a hash of the raw
/// body, so the body can't be swapped under a captured signature. The HMAC key is
/// the license's own secret key, which the app keeps from mint (check-in never
/// returns it, I17).
///
/// The committed parity vector is
/// `supabase/functions/license/fixtures/jc5-signature-vector.json`; the signer
/// test feeds it the vector's `(key, method, path, timestamp, nonce, body)` and
/// asserts the produced `signature` equals the fixture's.
internal struct StowerCheckInSignature: Sendable {
    /// The three signed headers a check-in request carries.
    internal struct Headers: Sendable, Equatable {
        /// `X-Stower-Timestamp` — unix seconds, also part of the signed message.
        internal let timestamp: String

        /// `X-Stower-Nonce` — a fresh random token, also part of the signed message.
        internal let nonce: String

        /// `X-Stower-Signature` — lower-case hex HMAC-SHA256 over the canonical message.
        internal let signature: String
    }

    /// Signs a check-in request, returning the `X-Stower-*` header values.
    ///
    /// The canonical message is `[METHOD, path, timestamp, nonce, sha256hex(body)]`
    /// joined by `"\n"`; `signature` is the lower-case hex HMAC-SHA256 of that
    /// message under the UTF-8 bytes of `key`.
    ///
    /// - Parameters:
    ///   - method: The HTTP method; upper-cased into the message.
    ///   - path: The canonical signing path — defaults to `"/check-in"`, NEVER the
    ///     Supabase-prefixed request pathname (which would fail the verify).
    ///   - timestamp: Unix seconds as a string.
    ///   - nonce: A fresh random token, unique per request.
    ///   - body: The exact request-body bytes that will be POSTed.
    ///   - key: The license's secret key (the per-license HMAC secret).
    /// - Returns: The `X-Stower-*` timestamp, nonce, and signature header values.
    internal func sign(
        method: String,
        path: String = StowerCheckInSignature.signingPath,
        timestamp: String,
        nonce: String,
        body: Data,
        key: String
    ) -> Headers {
        let message = [
            method.uppercased(),
            path,
            timestamp,
            nonce,
            Self.sha256Hex(body)
        ].joined(separator: "\n")
        return Headers(
            timestamp: timestamp,
            nonce: nonce,
            signature: Self.hmacSha256Hex(key: key, message: message)
        )
    }

    /// Lower-case hex SHA-256 of `data`.
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lower-case hex HMAC-SHA256 of `message` under the UTF-8 bytes of `key`.
    private static func hmacSha256Hex(key: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// The canonical, deployment-independent path the signature commits to —
    /// matches `CHECK_IN_SIGNING_PATH` in the Edge Function's `index.ts`.
    internal static let signingPath = "/check-in"

    /// The `X-Stower-Timestamp` header carrying the unix-seconds timestamp.
    internal static let timestampHeader = "X-Stower-Timestamp"

    /// The `X-Stower-Nonce` header carrying the per-request nonce.
    internal static let nonceHeader = "X-Stower-Nonce"

    /// The `X-Stower-Signature` header carrying the lower-case hex signature.
    internal static let signatureHeader = "X-Stower-Signature"
}
