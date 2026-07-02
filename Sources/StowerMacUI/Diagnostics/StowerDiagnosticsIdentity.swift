import Foundation
import Security

/// Storage location for the diagnostics install record.
///
/// A case-less namespace because the key has no single natural home type: both
/// `StowerDiagnosticsIdentity` and `StowerDiagnosticsConsent` read/write the same
/// one `UserDefaults` blob. The key is distinct from the disclosure "shown" flag
/// (`StowerDiagnosticsConsent.shownDefaultsKey`) so the two never collide.
internal enum StowerDiagnosticsStorageLocation {
    /// The `UserDefaults` key holding the diagnostics install record blob.
    internal static let defaultsKey = "com.stower.analytics.install-record"
}

/// A stable, anonymous, random install identity stored in `UserDefaults`.
///
/// `clientUser()` returns the same random UUID across relaunches and across
/// uninstall→reinstall (`UserDefaults` persists in `~/Library/Preferences`, so
/// it survives). On a fresh install with no stored record it mints a new random
/// UUID and persists it.
///
/// The identity is NOT hardware-derived, NOT IDFV/IDFA — it is a plain random
/// `UUID()`, app-scoped, with no cross-device or cross-app meaning (JC4).
/// Anonymity is the double-hash (salt + SHA-256) TelemetryDeck applies before
/// the value ever leaves the device; the UUID itself never travels the network.
internal struct StowerDiagnosticsIdentity: Sendable {
    private let storage: any StowerLeaseStorage
    private let legacyKeychainRead: @Sendable () -> Data?

    /// Creates the identity accessor.
    ///
    /// - Parameters:
    ///   - storage: The persistence seam. Defaults to the real
    ///     `UserDefaults`-backed store; inject an in-memory fake for tests so
    ///     they never touch `UserDefaults`.
    ///   - legacyKeychainRead: Reads an upgrading install's pre-migration
    ///     record. Defaults to the real Keychain read; inject a fake for tests
    ///     so they never touch the Keychain.
    internal init(
        storage: any StowerLeaseStorage = StowerUserDefaultsItem(
            key: StowerDiagnosticsStorageLocation.defaultsKey
        ),
        legacyKeychainRead: @escaping @Sendable () -> Data? = Self.readLegacyKeychainRecord
    ) {
        self.storage = storage
        self.legacyKeychainRead = legacyKeychainRead
    }

    /// Returns the stable install identifier, minting and persisting a fresh
    /// random UUID if none is stored yet.
    ///
    /// Checks the legacy Keychain location before minting fresh: an install
    /// that predates the `UserDefaults` move has its real identity and
    /// opt-out cache there, and silently minting a new UUID would both lose
    /// analytics continuity AND silently re-enable a user who'd opted out
    /// (`DiagnosticsInstallRecord.enabled` defaults `true` on a fresh mint).
    /// A concurrent first-launch race would at worst persist one of two freshly
    /// minted UUIDs; every read thereafter is a stable single value.
    internal func clientUser() -> String {
        if let existing = storedRecord() {
            return existing.id
        }
        if let migrated = migrateFromLegacyKeychain() {
            return migrated.id
        }
        // Fresh install or missing record — mint a new UUID and store it.
        let fresh = UUID().uuidString
        let record = DiagnosticsInstallRecord(id: fresh, enabled: true)
        if let data = try? JSONEncoder().encode(record) {
            storage.write(data)
        }
        return fresh
    }

    private func storedRecord() -> DiagnosticsInstallRecord? {
        guard let data = storage.readData() else { return nil }
        guard
            let record = try? JSONDecoder().decode(DiagnosticsInstallRecord.self, from: data),
            UUID(uuidString: record.id) != nil
        else { return nil }
        return record
    }

    /// One-time migration for an upgrading install: copies the legacy
    /// Keychain record forward into `UserDefaults` and returns it.
    ///
    /// Only ever reached from `clientUser()` when `storedRecord()` found
    /// nothing — so this runs at most once per install. The legacy item is
    /// left in place (not deleted): removing it would need Keychain write
    /// access this type deliberately doesn't have, for no benefit over
    /// harmless orphaned data.
    private func migrateFromLegacyKeychain() -> DiagnosticsInstallRecord? {
        guard
            let data = legacyKeychainRead(),
            let record = try? JSONDecoder().decode(DiagnosticsInstallRecord.self, from: data),
            UUID(uuidString: record.id) != nil
        else { return nil }
        if let reencoded = try? JSONEncoder().encode(record) {
            storage.write(reencoded)
        }
        return record
    }

    /// Reads the pre-migration Keychain item directly.
    ///
    /// Read-only, since the writable `StowerKeychainItem` type this identity
    /// used before the `UserDefaults` move was removed. Coordinates are
    /// unchanged from the original analytics types
    /// (`StowerDiagnosticsLegacyKeychainKeys`) so an upgrading install's
    /// existing item is found.
    private static func readLegacyKeychainRecord() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: StowerDiagnosticsLegacyKeychainKeys.service,
            kSecAttrAccount as String: StowerDiagnosticsLegacyKeychainKeys.account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return data
    }
}

/// The now-legacy Keychain coordinates the diagnostics install record used to live at.
///
/// Kept only so `StowerDiagnosticsIdentity` can find an upgrading install's
/// existing record. Never written to — new records live in `UserDefaults`
/// (`StowerDiagnosticsStorageLocation`).
private enum StowerDiagnosticsLegacyKeychainKeys {
    internal static let service = "com.stower.analytics.identity"
    internal static let account = "install-record"
}

// MARK: — Shared install record

/// The diagnostics install record persisted in `UserDefaults`.
///
/// Both `StowerDiagnosticsIdentity` and `StowerDiagnosticsConsent` read/write
/// the same one `UserDefaults` blob so the UUID and the cached opt-out are never
/// stored in separate places that could desync.
internal struct DiagnosticsInstallRecord: Codable, Sendable {
    /// The random per-install UUID (not hardware/IDFV/IDFA).
    internal var id: String

    /// Whether the user has opted in (`true` = on, default).
    ///
    /// This is the fast local cache of the license-scoped `diagnostics_opt_out`
    /// decision; "off wins" (the license record is authoritative, JC8).
    internal var enabled: Bool
}
