import Foundation

/// A persisted license: the activated key plus the device `instance.id` Lemon
/// Squeezy bound at activation.
///
/// `instance_id` is captured free from the activate response and kept for the
/// next ticket's `/validate` / `/deactivate`; no v1 logic reads it. Nothing else
/// from the response (notably `meta.customer_email`) is ever stored here.
internal struct StowerStoredLicense: Sendable, Equatable {
    /// The license key, in its trimmed form (equals the activated key).
    internal let key: String

    /// The Lemon Squeezy instance id returned by `/v1/licenses/activate`.
    internal let instanceID: String
}

/// Plaintext `UserDefaults`-backed read/write of the stored license.
///
/// Deliberately plaintext, not Keychain: a license key is a low-value bearer
/// token the user already holds in email, so this is an anti-casual-copy gate,
/// not tamper-proof storage (honest about the limitation). There is no `clear()`
/// in v1 — nothing invalidates a stored key, so the store needs only read + write;
/// `clear()` arrives with the next ticket's refund handling.
///
/// `UserDefaults` is documented thread-safe but not `Sendable`; the property is
/// marked `nonisolated(unsafe)` so the store can cross the `Sendable` license seam
/// without making the whole type `@unchecked Sendable`.
internal struct StowerLicenseStore: Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults

    /// Creates a store over the given defaults.
    ///
    /// - Parameter defaults: The backing store; injectable so tests use an
    ///   ephemeral suite and never touch the real domain.
    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reads the stored license, or `nil` if either field is absent.
    internal func read() -> StowerStoredLicense? {
        guard let key = defaults.string(forKey: Self.keyDefaultsKey),
            let instanceID = defaults.string(forKey: Self.instanceIDDefaultsKey)
        else {
            return nil
        }
        return StowerStoredLicense(key: key, instanceID: instanceID)
    }

    /// Persists the license key and instance id.
    internal func write(_ license: StowerStoredLicense) {
        defaults.set(license.key, forKey: Self.keyDefaultsKey)
        defaults.set(license.instanceID, forKey: Self.instanceIDDefaultsKey)
    }

    private static let keyDefaultsKey = "com.stower.license.key"
    private static let instanceIDDefaultsKey = "com.stower.license.instanceID"
}
