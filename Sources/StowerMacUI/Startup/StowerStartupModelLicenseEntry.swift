import Foundation

/// The board ⇄ key-entry navigation (JC5): jumping to the key-entry screen from
/// the board and backing out of it again, split from `StowerStartupModel.swift`
/// to keep that file within its length budget (the same posture as the
/// `Analytics`/`Availability` extensions).
extension StowerStartupModel {
    /// Jumps to the key-entry screen from the board (JC5): the gear menu's
    /// "Enter license key…" item and the F2 banner both call this so a mid-trial
    /// purchaser isn't forced to wait until expiry to activate.
    ///
    /// Cancels any in-flight run and bumps the generation, mirroring
    /// `handleBoardFailure` — a late startup completion can't overwrite this.
    /// Does NOT emit a funnel event: this is a voluntary mid-trial visit, not
    /// the forced paywall routing `hardware_checked`/`paywall_reached` measure.
    internal func showLicenseEntry() {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        commit(.needsLicense(nil), generation: generation, emitsFunnelEvent: false)
        licenseEntryIsDismissible = true
    }

    /// Backs a voluntary key-entry visit out to the board (JC5).
    ///
    /// No startup rerun — a mid-trial peek keeps its board; re-reads the license
    /// locally and routes to the paywall instead if the trial lapsed meanwhile.
    /// Emits no funnel event; a no-op unless a Back is actually being offered.
    internal func dismissLicenseEntry() {
        guard licenseEntryIsDismissible else { return }
        licenseEntryIsDismissible = false
        generation += 1
        switch licenseGate.licenseState(now: clock()) {
        case .licensed, .trial:
            commit(.connectedPreparingBoard, generation: generation, emitsFunnelEvent: false)
        case .expired:
            commit(.needsLicense(nil), generation: generation, emitsFunnelEvent: false)
        }
    }
}
