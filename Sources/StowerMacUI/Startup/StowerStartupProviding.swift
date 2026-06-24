import Foundation

/// The app-owned startup boundary the SwiftUI layer depends on.
///
/// Exactly the two calls this onboarding slice needs. `loadDebtBoard` returns
/// nothing the slice renders — a success drives the connected-loading state, a
/// throw drives routing. The signature is **permanent**: the board arrives via a
/// separate seam, never by growing this method. The real
/// `StowerMessagesStartupAdapter` and the Tests-only `StowerFakeStartupProvider`
/// both conform; only the adapter imports the engine.
internal protocol StowerStartupProviding: Sendable {
    /// Whether the on-device model can serve verdicts; checked before board work.
    func modelAvailability() async -> StowerStartupModelAvailability

    /// Probes the board load to drive routing; the returned board is discarded.
    ///
    /// Succeeds (→ connected-loading) or throws a `StowerStartupFailure` the
    /// startup model routes. `CancellationError` propagates unchanged.
    func loadDebtBoard(config: StowerStartupDebtConfig, now: Date) async throws
}
