import Foundation

/// A process-wide, in-memory diagnostics opt-out latch.
///
/// The `UserDefaults` `enabled` field is the persistent cache, but multiple
/// reporter instances (facade, board, startup) each re-read it per signal. If a
/// user opts out and the UserDefaults write *fails*, those reporters would read
/// the stale "on" value and keep emitting. This latch closes that gap: once
/// `StowerDiagnostics.setEnabled(false)` latches off, every reporter honors it
/// immediately this session — independent of whether the UserDefaults write
/// succeeded. Durable off across launches lives in the `UserDefaults` `enabled`
/// field; the license `diagnostics_opt_out` reconcile hook (JC8) is unwired.
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
/// The authoritative local consent value is the pair of fields inside the
/// diagnostics install record in `UserDefaults`: `hasExplicitChoice` must be
/// true and `enabled` must be true. Missing/corrupt storage, or migrated records
/// that predate `hasExplicitChoice`, are treated as no explicit choice and
/// therefore disabled.
///
/// **Precedence: "off wins."** Diagnostics is off if EITHER the (unwired) license
/// reconcile OR the UserDefaults cache says off. Only an explicit user action re-enables.
///
/// The record lives in `UserDefaults`, not the Keychain: it holds only an
/// anonymous UUID and an opt-out cache (never a secret), and a Keychain read on
/// the launch path raised a password dialog before the first window drew.
internal struct StowerDiagnosticsConsent: Sendable {
    private let storage: any StowerLeaseStorage

    /// Creates the consent accessor.
    ///
    /// - Parameter storage: The persistence seam (same store as
    ///   `StowerDiagnosticsIdentity`). Defaults to the real `UserDefaults`-backed
    ///   store; inject an in-memory fake for tests.
    internal init(
        storage: any StowerLeaseStorage = StowerUserDefaultsItem(
            key: StowerDiagnosticsStorageLocation.defaultsKey
        )
    ) {
        self.storage = storage
    }

    // MARK: — Enabled / disabled

    /// Whether diagnostics collection is currently enabled.
    ///
    /// Reads the UserDefaults cache. Returns `false` when no explicit user
    /// choice exists yet, so a fresh install performs no diagnostics collection
    /// before consent.
    ///
    /// The in-memory `StowerDiagnosticsKillLatch` wins over the cache: once the
    /// user opts out this session, this returns `false` even if the UserDefaults
    /// write failed (so every reporter stops immediately).
    internal var isEnabled: Bool {
        if StowerDiagnosticsKillLatch.isLatchedOff { return false }
        guard let record = readRecord(), record.hasExplicitChoice else { return false }
        return record.enabled
    }

    /// Whether the user has explicitly accepted or declined diagnostics.
    internal var hasMadeExplicitChoice: Bool {
        readRecord()?.hasExplicitChoice ?? false
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
            readRecord()
            ?? DiagnosticsInstallRecord(
                id: UUID().uuidString,
                enabled: false,
                hasExplicitChoice: false
            )
        record.enabled = enabled
        record.hasExplicitChoice = true
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
            readRecord()
            ?? DiagnosticsInstallRecord(
                id: UUID().uuidString,
                enabled: false,
                hasExplicitChoice: false
            )
        if record.enabled || !record.hasExplicitChoice {
            record.enabled = false
            record.hasExplicitChoice = true
            writeRecord(record)
        }
    }

    // MARK: — Private helpers

    private func readRecord() -> DiagnosticsInstallRecord? {
        guard let data = storage.readData(),
            let record = try? JSONDecoder().decode(DiagnosticsInstallRecord.self, from: data)
        else {
            // Missing OR undecodable — treat as no explicit choice.
            return nil
        }
        return record
    }

    @discardableResult
    private func writeRecord(_ record: DiagnosticsInstallRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return storage.write(data)
    }
}
