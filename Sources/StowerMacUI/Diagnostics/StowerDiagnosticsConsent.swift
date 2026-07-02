import Foundation

/// A process-wide, in-memory diagnostics opt-out latch.
///
/// The `UserDefaults` `enabled` field is the persistent cache, but multiple
/// reporter instances (facade, board, startup) each re-read it per signal. If a
/// user opts out and the UserDefaults write *fails*, those reporters would read
/// the stale "on" value and keep emitting. This latch closes that gap: once
/// `StowerDiagnostics.setEnabled(false)` latches off, every reporter honors it
/// immediately this session — independent of whether the UserDefaults write
/// succeeded. Durable off across launches is backstopped by the license
/// `diagnostics_opt_out` reconcile (JC8).
///
/// Thread-safe (lock-guarded) because reporters may emit off the main actor.
/// Never re-enables itself; only an explicit user opt-in (`reset()`) clears it.
internal enum StowerDiagnosticsKillLatch {
    private static let lock = NSLock()
    /// Guarded by `lock` — `nonisolated(unsafe)` asserts that manual locking,
    /// not the compiler, provides the concurrency safety.
    nonisolated(unsafe) private static var optedOut = false

    /// Whether diagnostics has been latched off in memory this session.
    internal static var isLatchedOff: Bool {
        lock.lock()
        defer { lock.unlock() }
        return optedOut
    }

    /// Latches diagnostics off for the rest of this session.
    internal static func latchOff() {
        lock.lock()
        defer { lock.unlock() }
        optedOut = true
    }

    /// Clears the latch (explicit user opt-in, or test teardown).
    internal static func reset() {
        lock.lock()
        defer { lock.unlock() }
        optedOut = false
    }
}

/// Manages the diagnostics consent state (analytics + crash reporting).
///
/// Consent is **license-scoped** (JC8): the authoritative source of truth is
/// the license record's `diagnostics_opt_out` field (parallel licensing
/// workstream). The **`enabled` field** inside the diagnostics install record
/// is the **fast local cache** used at launch and when offline.
///
/// **Precedence: "off wins."** Diagnostics is off if EITHER the license record
/// OR the UserDefaults cache says off. Only an explicit user action re-enables.
///
/// The **first-run-shown** flag for the disclosure card lives in `UserDefaults`
/// under a separate key — not in the consent/identity install record.
///
/// The record lives in `UserDefaults`, not the Keychain: it holds only an
/// anonymous UUID and an opt-out cache (never a secret), and a Keychain read on
/// the launch path raised a password dialog before the first window drew.
internal struct StowerDiagnosticsConsent: Sendable {
    private let storage: any StowerLeaseStorage
    private let legacyKeychainRead: @Sendable () -> Data?

    /// The `UserDefaults` key for the first-run disclosure card shown-flag.
    internal static let shownDefaultsKey = "com.stower.analytics.shown"

    /// Creates the consent accessor.
    ///
    /// - Parameters:
    ///   - storage: The persistence seam (same store as
    ///     `StowerDiagnosticsIdentity`). Defaults to the real `UserDefaults`-backed
    ///     store; inject an in-memory fake for tests.
    ///   - legacyKeychainRead: Reads an upgrading install's pre-migration
    ///     opt-out. Defaults to the same real Keychain read
    ///     `StowerDiagnosticsIdentity` uses; inject a fake for tests so they
    ///     never touch the Keychain.
    internal init(
        storage: any StowerLeaseStorage = StowerUserDefaultsItem(
            key: StowerDiagnosticsStorageLocation.defaultsKey
        ),
        legacyKeychainRead: @escaping @Sendable () -> Data? =
            StowerDiagnosticsIdentity.readLegacyKeychainRecord
    ) {
        self.storage = storage
        self.legacyKeychainRead = legacyKeychainRead
    }

    // MARK: — Enabled / disabled

    /// Whether diagnostics collection is currently enabled.
    ///
    /// Reads the UserDefaults cache. Returns `true` (default-on) when no record
    /// exists yet (fresh install). This is the fast at-launch gate; the license
    /// record is authoritative and reconciled on each check-in.
    ///
    /// The in-memory `StowerDiagnosticsKillLatch` wins over the cache: once the
    /// user opts out this session, this returns `false` even if the UserDefaults
    /// write failed (so every reporter stops immediately).
    internal var isEnabled: Bool {
        if StowerDiagnosticsKillLatch.isLatchedOff { return false }
        return readRecord()?.enabled ?? true
    }

    /// Enables or disables diagnostics collection.
    ///
    /// Writes the choice immediately to UserDefaults (instant local effect).
    /// The caller is responsible for pushing `diagnostics_opt_out` to the
    /// license record (durable, license-scoped store, parallel workstream).
    ///
    /// - Returns: `true` if the UserDefaults cache write succeeded. A `false` return
    ///   means the local cache could not be updated; the caller's facade fails
    ///   closed in memory for the session and the license record remains the
    ///   durable authority (JC8).
    @discardableResult
    internal func setEnabled(_ enabled: Bool) -> Bool {
        var record =
            readRecord() ?? DiagnosticsInstallRecord(id: UUID().uuidString, enabled: true)
        record.enabled = enabled
        return writeRecord(record)
    }

    /// Reconciles the UserDefaults cache against the authoritative license record.
    ///
    /// If the license says off but the cache says on (a wiped-storage case where
    /// the user opted out on another install), this turns off the local cache.
    /// "Off wins" — this method never re-enables diagnostics; only an explicit
    /// user action does that.
    ///
    /// Call this on each license check-in when `diagnostics_opt_out` is returned.
    ///
    /// - Parameter licenseOptOut: `true` when the license record says the user
    ///   has opted out.
    internal func reconcile(licenseOptOut: Bool) {
        guard licenseOptOut else { return }
        // License says off — ensure the local cache reflects it.
        var record =
            readRecord() ?? DiagnosticsInstallRecord(id: UUID().uuidString, enabled: true)
        if record.enabled {
            record.enabled = false
            writeRecord(record)
        }
    }

    // MARK: — First-run shown flag

    /// Whether the diagnostics disclosure card has already been shown this install.
    internal var hasShownDisclosure: Bool {
        UserDefaults.standard.bool(forKey: Self.shownDefaultsKey)
    }

    /// Marks the disclosure card as shown so it never appears again.
    internal func markDisclosureShown() {
        UserDefaults.standard.set(true, forKey: Self.shownDefaultsKey)
    }

    // MARK: — Private helpers

    private func readRecord() -> DiagnosticsInstallRecord? {
        // Falls through to migration on ANY failure to produce a record — data
        // missing entirely, or present but undecodable (matches
        // StowerDiagnosticsIdentity.storedRecord()'s same fall-through via
        // clientUser(), so corrupted UserDefaults doesn't skip a real
        // pre-migration opt-out and re-enable diagnostics for that launch).
        guard let data = storage.readData(),
            let record = try? JSONDecoder().decode(DiagnosticsInstallRecord.self, from: data)
        else {
            return migrateFromLegacyKeychain()
        }
        return record
    }

    /// One-time migration for an install predating the `UserDefaults` move.
    ///
    /// Its opt-out lives in the legacy Keychain item, not yet migrated. Mirrors
    /// `StowerDiagnosticsIdentity`'s own migration, deliberately independent —
    /// see the `legacyKeychainRead` parameter doc. Once this (or Identity's)
    /// migration writes the record into `storage`, every later `readRecord()`
    /// this launch finds it there and never reaches the Keychain again.
    private func migrateFromLegacyKeychain() -> DiagnosticsInstallRecord? {
        guard
            let data = legacyKeychainRead(),
            let record = try? JSONDecoder().decode(DiagnosticsInstallRecord.self, from: data),
            UUID(uuidString: record.id) != nil
        else { return nil }
        storage.write(data)
        return record
    }

    @discardableResult
    private func writeRecord(_ record: DiagnosticsInstallRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return storage.write(data)
    }
}
