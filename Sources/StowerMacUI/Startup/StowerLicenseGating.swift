import Foundation

/// The pure-local license verdict the startup model routes on.
///
/// Produced by `StowerLicenseGating.licenseState(now:)` — a synchronous local
/// read (stored license, else the trial clock). Distinct from
/// `StowerLicenseActivation`, which is the async `/activate` network verdict.
internal enum StowerLicenseState: Sendable, Equatable {
    /// A license key is stored; the app runs fully offline forever.
    case licensed

    /// No stored license; the free trial is still active, ending at `expiry`.
    case trial(expiry: Date)

    /// No stored license and the 7-day trial has elapsed.
    case expired
}

/// The trial status badge data: the trial end date.
///
/// Present only on an active free trial; there is no licensed-state badge (a
/// licensed launch never constructs one).
internal struct StowerTrialBadge: Sendable, Equatable {
    /// The trial end date, from `StowerTrialClock.state(now:)`.
    internal let expiry: Date
}

/// The startup license seam: a pure-local state read, a pure network activate,
/// and a persist step the caller invokes only after its own generation guard.
///
/// Parallel to `StowerStartupProviding`. The production conformer is
/// `StowerLemonSqueezyLicenseGate`; tests pass `StowerFakeLicenseGate`.
internal protocol StowerLicenseGating: Sendable {
    /// Whether the trial clock has never been observed before this call — i.e.
    /// the very next `licenseState(now:)` call is the one that starts the
    /// 7-day trial, not a read of an already-running one.
    ///
    /// Callers that emit a "trial started" analytics event must check this
    /// BEFORE calling `licenseState(now:)`: once that call runs, the trial
    /// clock is always seeded, so checking after can't distinguish a true
    /// first launch from a relaunch mid-trial. Always `false` once a license
    /// is stored (a licensed device never seeds a trial clock read this way).
    func isFirstTrialObservation(now: Date) -> Bool

    /// Resolves the current license state: a pure local read of the stored
    /// license, else the trial clock. No network.
    func licenseState(now: Date) -> StowerLicenseState

    /// Activates `key` against Lemon Squeezy — the app's only network call.
    ///
    /// Pure: never persists. The caller persists only after its own
    /// generation check (I4), via `persist(key:instanceID:)`.
    func activate(key: String) async -> StowerLicenseActivation

    /// Persists an activated key + its bound Lemon Squeezy instance id.
    func persist(key: String, instanceID: String)
}
