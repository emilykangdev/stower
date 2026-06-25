import Foundation

/// The outcome of one Lemon Squeezy `/v1/licenses/activate` round-trip.
internal enum StowerLicenseActivation: Sendable, Equatable {
    /// Verified; carries the bound `instance.id` to persist.
    case activated(instanceID: String)

    /// Lemon Squeezy was reached and said no (bad key / device limit reached).
    case invalid

    /// Transport/5xx/undecodable — recoverable; also the offline first-run case.
    case couldNotReach
}

/// The entry-screen error carried by `StowerStartupState.needsLicense`.
internal enum StowerLicenseGateError: Sendable, Equatable {
    /// Lemon Squeezy was reached and said no — re-check the copied key.
    case invalid

    /// Couldn't reach the license server — retry once connectivity returns.
    case couldNotReach
}

/// The startup license seam: a pure-local launch read, a pure activate, and a
/// separate persist the model calls only after a generation check.
///
/// Parallel to `StowerStartupProviding` — licensing never grows that seam. The
/// production conformer is `StowerLemonSqueezyLicenseGate`; tests pass
/// `StowerFakeLicenseGate`. `activate` is deliberately split from `persistLicense`
/// so a superseded activation can never write a key a newer submit rejected.
internal protocol StowerLicenseGating: Sendable {
    /// Whether a license is already stored — a pure local `UserDefaults` read, no
    /// network. The launch path; a stored key ⇒ licensed (no `/validate` in v1).
    func hasStoredLicense() -> Bool

    /// Activates `key` against Lemon Squeezy. PURE — never persists.
    func activate(key: String) async -> StowerLicenseActivation

    /// Persists `{key, instanceID}`; the model calls this only after confirming
    /// the activation is still the current generation.
    func persistLicense(key: String, instanceID: String)
}
