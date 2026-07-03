import Foundation

/// A user's coarse license status at the time they sent feedback.
///
/// Encoded by `rawValue` in the feedback payload. `unlicensed` is a defensive
/// default only — a user on the board is always trial or paid
/// (`StowerRootView.screen` routes unlicensed users to the paywall, never the
/// board).
internal enum StowerFeedbackLicenseStatus: String, Sendable, Equatable {
    case trial
    case paid
    case unlicensed
}

/// The outcome of one feedback POST to the Deno relay.
internal enum StowerFeedbackSendResult: Sendable, Equatable {
    /// The relay accepted the feedback (HTTP 2xx).
    case sent

    /// Transport throw, or any non-2xx status — the app shows an inline error + Retry.
    case failed
}

/// The feedback payload sent to the Deno relay — the single source of truth for
/// the app→Deno contract (matches `deno/feedback/main.ts`, camelCase).
///
/// The `key` never appears here: only the opaque `instanceID` (or `null` for a
/// trial/unlicensed user) crosses the wire, so a leaked at-rest copy in Resend
/// logs or Emily's inbox exposes no seat-hijack bearer token (JC1,
/// I-InstanceIDNotKey). `email` is nullable — a blank email is mapped to `nil`
/// before construction so it encodes as JSON `null`, never `""`
/// (I-BlankEmailNull).
///
/// Default (camelCase) `CodingKeys` — no overrides — so the encoded keys match
/// `deno/feedback/main.ts`'s decode (`message`, `email`, `instanceID`,
/// `appVersion`, `osVersion`, `licenseStatus`).
internal struct StowerFeedbackSubmission: Encodable, Sendable, Equatable {
    /// The user's trimmed feedback message (1...5000 chars).
    internal let message: String

    /// The optional reply address; `nil` (encoded as JSON `null`) when blank.
    internal let email: String?

    /// The opaque Lemon Squeezy instance id; `nil` for a trial/unlicensed user.
    internal let instanceID: String?

    /// The app version, e.g. `"1.0 (1)"`.
    internal let appVersion: String

    /// The OS version, e.g. `"macOS 15.4"`.
    internal let osVersion: String

    /// The user's coarse license status.
    internal let licenseStatus: StowerFeedbackLicenseStatus

    private enum CodingKeys: String, CodingKey {
        case message, email, instanceID, appVersion, osVersion, licenseStatus
    }

    /// Encodes the payload, writing `licenseStatus` as its `rawValue` string and
    /// a `nil` `email`/`instanceID` as JSON `null`.
    internal func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encode(email, forKey: .email)
        try container.encode(instanceID, forKey: .instanceID)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(licenseStatus.rawValue, forKey: .licenseStatus)
    }
}
