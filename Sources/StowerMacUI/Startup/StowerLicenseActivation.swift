import Foundation

/// The outcome of one Lemon Squeezy `/v1/licenses/activate` round-trip.
internal enum StowerLicenseActivation: Sendable, Equatable {
    /// Verified; carries the bound `instance.id` to persist.
    case activated(instanceID: String)

    /// Lemon Squeezy was reached and said no (bad key / device limit reached / a
    /// key for another store or product).
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
