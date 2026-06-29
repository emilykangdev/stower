import Foundation

/// Manages the analytics consent state.
///
/// Consent is **license-scoped** (JC8): the authoritative source of truth is
/// the license record's `diagnostics_opt_out` field (parallel licensing
/// workstream). The **Keychain `enabled` field** inside the analytics install
/// record is the **fast local cache** used at launch and when offline.
///
/// **Precedence: "off wins."** Analytics is off if EITHER the license record OR
/// the Keychain cache says off. Only an explicit user action re-enables.
///
/// The **first-run-shown** flag for the disclosure card lives in `UserDefaults`
/// (ephemeral UI state only) — not in the consent/identity Keychain record.
internal struct StowerAnalyticsConsent: Sendable {
    private let storage: any StowerLeaseStorage

    /// The `UserDefaults` key for the first-run disclosure card shown-flag.
    internal static let shownDefaultsKey = "com.stower.analytics.shown"

    /// Creates the consent accessor.
    ///
    /// - Parameter storage: The persistence seam (same item as
    ///   `StowerAnalyticsIdentity`). Defaults to the real Keychain item; inject
    ///   an in-memory fake for tests.
    internal init(
        storage: any StowerLeaseStorage = StowerKeychainItem(
            service: StowerAnalyticsKeychainKeys.service,
            account: StowerAnalyticsKeychainKeys.account
        )
    ) {
        self.storage = storage
    }

    // MARK: — Enabled / disabled

    /// Whether analytics collection is currently enabled.
    ///
    /// Reads the Keychain cache. Returns `true` (default-on) when no record
    /// exists yet (fresh install). This is the fast at-launch gate; the license
    /// record is authoritative and reconciled on each check-in.
    internal var isEnabled: Bool {
        readRecord()?.enabled ?? true
    }

    /// Disables analytics collection.
    ///
    /// Writes the opt-out immediately to the Keychain (instant local effect).
    /// The caller is responsible for pushing `diagnostics_opt_out` to the
    /// license record (durable, license-scoped store, parallel workstream).
    internal func setEnabled(_ enabled: Bool) {
        var record = readRecord() ?? AnalyticsInstallRecord(id: UUID().uuidString, enabled: true)
        record.enabled = enabled
        writeRecord(record)
    }

    /// Reconciles the Keychain cache against the authoritative license record.
    ///
    /// If the license says off but the cache says on (a wiped-Keychain case where
    /// the user opted out on another install), this turns off the local cache.
    /// "Off wins" — this method never re-enables analytics; only an explicit
    /// user action does that.
    ///
    /// Call this on each license check-in when `diagnostics_opt_out` is returned.
    ///
    /// - Parameter licenseOptOut: `true` when the license record says the user
    ///   has opted out.
    internal func reconcile(licenseOptOut: Bool) {
        guard licenseOptOut else { return }
        // License says off — ensure the local cache reflects it.
        var record = readRecord() ?? AnalyticsInstallRecord(id: UUID().uuidString, enabled: true)
        if record.enabled {
            record.enabled = false
            writeRecord(record)
        }
    }

    // MARK: — First-run shown flag

    /// Whether the analytics disclosure card has already been shown this install.
    internal var hasShownDisclosure: Bool {
        UserDefaults.standard.bool(forKey: Self.shownDefaultsKey)
    }

    /// Marks the disclosure card as shown so it never appears again.
    internal func markDisclosureShown() {
        UserDefaults.standard.set(true, forKey: Self.shownDefaultsKey)
    }

    // MARK: — Private helpers

    private func readRecord() -> AnalyticsInstallRecord? {
        guard let data = storage.readData() else { return nil }
        return try? JSONDecoder().decode(AnalyticsInstallRecord.self, from: data)
    }

    private func writeRecord(_ record: AnalyticsInstallRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        storage.write(data)
    }
}
