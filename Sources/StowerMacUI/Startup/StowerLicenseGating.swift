import Foundation

/// The verdict of one license check (contract §5b): the gate state the startup
/// model routes on after availability.
///
/// Produced by `StowerLicenseGating.currentStatus`. `.wrongVersion` is distinct
/// from `.trialExpired` so the version-unlock model (§1) is enforceable — "trial
/// expired, buy it" vs. "valid license, just not for this build".
internal enum StowerLicenseStatus: Sendable, Equatable {
    /// Licensed: a fresh mint/check-in succeeded, or a signed offline lease allows
    /// this build before its TTL.
    case valid

    /// The trial clock ran out; carries the license id for the Buy checkout.
    case trialExpired(licenseID: String)

    /// Valid license missing this build's required entitlement; carries the id for
    /// the upgrade checkout.
    case wrongVersion(licenseID: String)

    /// A transient check-in failure on an existing lease with no usable offline
    /// authority — retry once connectivity returns.
    case couldNotReach

    /// No (or cleared) lease and the mint couldn't reach the server — a first-run
    /// / post-self-heal offline state, distinct from `.couldNotReach`.
    case needsTrialOnline
}

/// The entry-screen context carried by `StowerStartupState.needsLicense` — selects
/// the `StowerLicenseEntryView` variant.
internal enum StowerLicenseEntryContext: Sendable, Equatable {
    /// The trial ended; offer Buy (carrying `licenseID`) + Re-check.
    case trialExpired(licenseID: String)

    /// A valid license needs a cross-build upgrade; offer Buy (carrying `licenseID`)
    /// + Re-check. Distinct copy/target from `.trialExpired`.
    case upgradeRequired(licenseID: String)

    /// First-ever launch offline — can't mint without a connection; offer Retry.
    case connectOnce

    /// A transient license-server failure on an existing lease; offer Retry.
    case couldNotReach
}

/// The sub-label reason for `StowerStartupState.checkingLicense` — first run vs.
/// warm relaunch, so a paid relaunch never reads "Starting your free trial…".
internal enum StowerCheckingLicenseReason: Sendable, Equatable {
    /// No prior lease — minting a trial ("Starting your free trial…").
    case startingTrial

    /// A lease exists — revalidating ("Checking your license…").
    case revalidating
}

/// The startup license seam (contract §5b): a pure-local launch read and one
/// async status check.
///
/// The gate persists the lease internally on mint/check-in success — there is no
/// separate activate/persist (manual key activation is deferred to a future
/// backend-backed recovery route).
///
/// Parallel to `StowerStartupProviding`. The production conformer is
/// `StowerLicenseGate`; tests pass `StowerFakeLicenseGate`.
internal protocol StowerLicenseGating: Sendable {
    /// Whether a verified lease is already stored — a pure local Keychain read, no
    /// network. Picks the `.checkingLicense` reason and gates the JC6 self-heal.
    func hasLease() -> Bool

    /// Resolves the current license status: a reachable JC5-signed `/check-in` when
    /// a lease exists, mint-on-first-run otherwise, falling back to the signed
    /// offline lease (bounded by its TTL) when the server is unreachable.
    func currentStatus(now: Date) async -> StowerLicenseStatus
}
