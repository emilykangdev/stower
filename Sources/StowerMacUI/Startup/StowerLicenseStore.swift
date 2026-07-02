import Foundation

/// A persisted license: the activated key plus the device `instance.id` Lemon
/// Squeezy bound at activation.
///
/// `instance_id` is captured free from the activate response and kept for a
/// future `/validate` / `/deactivate`; no launch logic reads it. Nothing else
/// from the response (notably `meta.customer_email`) is ever stored here.
///
/// `Codable` so `StowerLicenseStore` persists both fields as one encoded
/// record under a single `UserDefaults` key — a crash between two separate
/// writes can never leave a real activation's `key` stored without its
/// `instanceID` (or vice versa), which would make an already-activated
/// license look absent on the next launch.
internal struct StowerStoredLicense: Sendable, Equatable, Codable {
    /// The license key, in its trimmed form (equals the activated key).
    internal let key: String

    /// The Lemon Squeezy instance id returned by `/v1/licenses/activate`.
    internal let instanceID: String
}

/// Plaintext `UserDefaults`-backed read/write of the stored license.
///
/// Deliberately plaintext, not Keychain: a license key is a low-value bearer
/// token the user already holds in email, so this is an anti-casual-copy gate,
/// not tamper-proof storage (honest about the limitation).
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

    /// Reads the stored license, or `nil` if absent or undecodable.
    ///
    /// One encoded record behind one key — never two independently-missing
    /// fields — so a torn write can only ever read back as "no license," not
    /// a corrupted partial one.
    internal func read() -> StowerStoredLicense? {
        guard let data = defaults.data(forKey: Self.licenseDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(StowerStoredLicense.self, from: data)
    }

    /// Persists the license key and instance id as one encoded record.
    internal func write(_ license: StowerStoredLicense) {
        guard let data = try? JSONEncoder().encode(license) else { return }
        defaults.set(data, forKey: Self.licenseDefaultsKey)
    }

    /// Removes the stored license (used by a failed re-activation / reset path).
    internal func clear() {
        defaults.removeObject(forKey: Self.licenseDefaultsKey)
    }

    private static let licenseDefaultsKey = "com.stower.license"
}
