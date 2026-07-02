import Foundation

/// A generic-blob persistence seam: read/write/delete of one opaque blob.
///
/// Production is `StowerUserDefaultsItem` (a single `Data` value in
/// `UserDefaults`); tests inject an in-memory fake so they touch neither
/// `UserDefaults` nor disk. This is the production storage for Diagnostics
/// (`StowerDiagnosticsConsent`, `StowerDiagnosticsIdentity`), not licensing.
internal protocol StowerLeaseStorage: Sendable {
    /// Reads the stored blob, or `nil` when absent.
    func readData() -> Data?

    /// Replaces the stored blob; returns whether the write succeeded.
    @discardableResult
    func write(_ data: Data) -> Bool

    /// Removes the stored blob.
    func delete()
}

/// The production `StowerLeaseStorage`: a single `Data` blob in `UserDefaults`.
///
/// Diagnostics stores only an anonymous, non-secret install record (a random
/// UUID plus the opt-out cache), so it lives in `UserDefaults` rather than the
/// Keychain. That is deliberate: a Keychain read on the launch path raised the
/// macOS "allow access to your keychain" password dialog *before the first
/// window drew*, a trust-wrecking first impression for data that was never
/// secret. `UserDefaults` has no such prompt, and — unlike a file — keeps the
/// UI slice off the filesystem (precheck 6d). It persists across relaunches and
/// survives uninstall→reinstall, matching the old Keychain item's lifetime.
internal struct StowerUserDefaultsItem: StowerLeaseStorage {
    private let key: String

    /// Creates an accessor for the `Data` value stored under `key` in
    /// `UserDefaults.standard`.
    ///
    /// - Parameter key: The `UserDefaults` key holding the blob. Tests never use
    ///   this type; they inject an in-memory `StowerLeaseStorage` fake, so the
    ///   store is fixed to `.standard` rather than injected (keeping the struct
    ///   `Sendable`, which a stored `UserDefaults` would break).
    internal init(key: String) {
        self.key = key
    }

    internal func readData() -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    @discardableResult
    internal func write(_ data: Data) -> Bool {
        UserDefaults.standard.set(data, forKey: key)
        // `UserDefaults.set` has no synchronous failure signal, so this always
        // reports success. The `Bool` exists only to satisfy the
        // `StowerLeaseStorage` contract shared with the Keychain-style store
        // this replaced, which could fail synchronously.
        return true
    }

    internal func delete() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
