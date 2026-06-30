import Foundation

/// The coarse, PII-safe cause of a license-unreachable resolution.
///
/// Carried on the licensing clients' `.unreachable` results and on the gate's
/// local-failure sites so `StowerLicenseGate` can report *why* a license check
/// could not produce a verdict (DNS/timeout vs. HTTP status vs. local-store
/// failure) — without ever carrying the URL, license key, license id, or
/// fingerprint. Pure data: no free-form strings, no logging.
///
/// Mapped to a bounded analytics token by
/// `StowerAnalyticsEvent.licenseUnreachable(reason:endpoint:)`; resist
/// per-incident detail here (that richer error inbox is PAR-53).
internal enum StowerLicenseUnreachableReason: Sendable, Equatable {
    /// A transport throw — DNS failure, timeout, no connection, 5xx-as-throw.
    case transport

    /// A non-success HTTP status the client cannot turn into a verdict; carries
    /// the status code so the token can distinguish e.g. a 500 from a 502.
    case httpStatus(Int)

    /// A 200 (or otherwise routable) body that failed to decode, or was missing a
    /// required field — never a half-verdict.
    case decodeFailure

    /// The request URL or body could not be built — a misconfigured endpoint.
    case badURL

    /// A local store (Keychain lease) read/write failed, so no verdict could be
    /// persisted or trusted.
    case localStoreFailure

    /// A minted/checked-in machine file failed to authorize this build/device, so
    /// it could not become a `.valid` the app can stand behind.
    case machineFileUnauthorized
}
