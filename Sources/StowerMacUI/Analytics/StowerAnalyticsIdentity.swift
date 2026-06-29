import Foundation

/// Keychain coordinates for the analytics install record.
///
/// A case-less namespace because the keys have no single natural home type:
/// both `StowerAnalyticsIdentity` and `StowerAnalyticsConsent` read/write the
/// same one-item entry. `service` is distinct from the license-lease service
/// (`com.stower.license.lease`) so the two records never collide; `account`
/// identifies the record within the service.
internal enum StowerAnalyticsKeychainKeys {
    /// The Keychain service identifier for the analytics install record.
    static let service = "com.stower.analytics.identity"

    /// The Keychain account key for the analytics install record.
    static let account = "install-record"
}

/// A stable, anonymous, random install identity stored in the Keychain.
///
/// `clientUser()` returns the same random UUID across relaunches and across
/// uninstall→reinstall (the Keychain item survives because the app is not
/// sandboxed — `ENABLE_APP_SANDBOX = NO`, verified A6). On a fresh install with
/// no stored record it mints a new random UUID and persists it.
///
/// The identity is NOT hardware-derived, NOT IDFV/IDFA — it is a plain random
/// `UUID()`, app-scoped, with no cross-device or cross-app meaning (JC4).
/// Anonymity is the double-hash (salt + SHA-256) TelemetryDeck applies before
/// the value ever leaves the device; the UUID itself never travels the network.
internal struct StowerAnalyticsIdentity: Sendable {
    private let storage: any StowerLeaseStorage

    /// Creates the identity accessor.
    ///
    /// - Parameter storage: The persistence seam. Defaults to the real Keychain
    ///   item; inject an in-memory fake for tests so they never touch the Keychain.
    internal init(
        storage: any StowerLeaseStorage = StowerKeychainItem(
            service: StowerAnalyticsKeychainKeys.service,
            account: StowerAnalyticsKeychainKeys.account
        )
    ) {
        self.storage = storage
    }

    /// Returns the stable install identifier, minting and persisting a fresh
    /// random UUID if none is stored yet.
    ///
    /// Thread-safe: `StowerKeychainItem` is a value type backed by Security
    /// framework calls, which are thread-safe.
    internal func clientUser() -> String {
        if let existing = storedRecord() {
            return existing.id
        }
        // Fresh install or missing record — mint a new UUID and store it.
        let fresh = UUID().uuidString
        let record = AnalyticsInstallRecord(id: fresh, enabled: true)
        if let data = try? JSONEncoder().encode(record) {
            storage.write(data)
        }
        return fresh
    }

    private func storedRecord() -> AnalyticsInstallRecord? {
        guard let data = storage.readData() else { return nil }
        return try? JSONDecoder().decode(AnalyticsInstallRecord.self, from: data)
    }
}

// MARK: — Shared install record

/// The analytics install record persisted in the Keychain.
///
/// Both `StowerAnalyticsIdentity` and `StowerAnalyticsConsent` read/write the
/// same one-item Keychain entry so the UUID and the cached opt-out are never
/// stored in separate items that could desync.
internal struct AnalyticsInstallRecord: Codable, Sendable {
    /// The random per-install UUID (not hardware/IDFV/IDFA).
    internal var id: String

    /// Whether the user has opted in (`true` = on, default).
    ///
    /// This is the fast local cache of the license-scoped `diagnostics_opt_out`
    /// decision; "off wins" (the license record is authoritative, JC8).
    internal var enabled: Bool
}
