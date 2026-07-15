import Foundation

/// Storage location for the diagnostics install record.
///
/// A case-less namespace because the key has no single natural home type: both
/// `StowerDiagnosticsIdentity` and `StowerDiagnosticsConsent` read/write the same
/// one `UserDefaults` blob.
internal enum StowerDiagnosticsStorageLocation {
    /// The `UserDefaults` key holding the diagnostics install record blob.
    internal static let defaultsKey = "com.stower.analytics.install-record"
}

/// A stable, anonymous, random install identity stored in `UserDefaults`.
///
/// `clientUser()` returns the same random UUID across relaunches and across
/// uninstall→reinstall (`UserDefaults` persists in `~/Library/Preferences`, so
/// it survives). On a fresh install with no stored record it mints a new random
/// UUID and persists it without granting diagnostics consent.
///
/// The identity is NOT hardware-derived, NOT IDFV/IDFA — it is a plain random
/// `UUID()`, app-scoped, with no cross-device or cross-app meaning (JC4).
/// Anonymity is the double-hash (salt + SHA-256) TelemetryDeck applies before
/// the value ever leaves the device; the UUID itself never travels the network.
internal struct StowerDiagnosticsIdentity: Sendable {
    private let storage: any StowerLeaseStorage

    /// Creates the identity accessor.
    ///
    /// - Parameter storage: The persistence seam. Defaults to the real
    ///   `UserDefaults`-backed store; inject an in-memory fake for tests so
    ///   they never touch `UserDefaults`.
    internal init(
        storage: any StowerLeaseStorage = StowerUserDefaultsItem(
            key: StowerDiagnosticsStorageLocation.defaultsKey
        )
    ) {
        self.storage = storage
    }

    /// Returns the stable install identifier, minting and persisting a fresh
    /// random UUID if none is stored yet.
    ///
    /// A concurrent first-launch race would at worst persist one of two freshly
    /// minted UUIDs; every read thereafter is a stable single value.
    internal func clientUser() -> String {
        if let existing = storedRecord() {
            return existing.id
        }
        // Fresh install or missing record — mint a new UUID and store it, but
        // do not count identity creation as diagnostics consent.
        let fresh = UUID().uuidString
        let record = DiagnosticsInstallRecord(
            id: fresh,
            enabled: false,
            hasExplicitChoice: false
        )
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
}

// MARK: — Shared install record

/// The diagnostics install record persisted in `UserDefaults`.
///
/// Both `StowerDiagnosticsIdentity` and `StowerDiagnosticsConsent` read/write
/// the same one `UserDefaults` blob so the UUID and the cached consent are never
/// stored in separate places that could desync.
internal struct DiagnosticsInstallRecord: Codable, Sendable {
    /// The random per-install UUID (not hardware/IDFV/IDFA).
    internal var id: String

    /// Whether diagnostics should run after an explicit choice.
    internal var enabled: Bool

    /// Whether `enabled` came from an explicit user or license choice.
    ///
    /// Missing on migrated records from the old default-on build, so decoding
    /// defaults it to `false` and launch stays diagnostics-dark until the user
    /// chooses.
    internal var hasExplicitChoice: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case hasExplicitChoice
    }

    internal init(id: String, enabled: Bool, hasExplicitChoice: Bool) {
        self.id = id
        self.enabled = enabled
        self.hasExplicitChoice = hasExplicitChoice
    }

    internal init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        hasExplicitChoice =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .hasExplicitChoice
            ) ?? false
    }
}
