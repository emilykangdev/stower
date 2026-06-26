import Foundation

/// The single state the root view renders during startup.
///
/// It carries the **typed** failure, not a `String`: the view derives every word
/// of user-facing copy from the case, so a raw engine string can never reach the
/// screen. The board-era cases (`.loadingJudgments`, `.ready`, `.allCaughtUp`)
/// are deliberately absent — they belong to the next slice's `refreshJudgments`
/// lifecycle, and adding them unused would be dead scaffold.
internal enum StowerStartupState: Sendable, Equatable {
    /// Checking whether the on-device model can serve verdicts.
    case checkingModel

    /// The model can't serve verdicts; the reason selects the screen variant.
    case modelUnavailable(StowerStartupModelUnavailableReason)

    /// The model is available but no license is stored yet; the entry screen is
    /// shown. A non-nil error means a prior activate attempt failed (retryable).
    case needsLicense(StowerLicenseGateError?)

    /// Activating the entered key against Lemon Squeezy — the only network call,
    /// first run only. Shown solely during the activate round-trip.
    case checkingLicense

    /// Model is available; attempting the board load behind the permission gate.
    case checkingMessages

    /// Full Disk Access is missing; `path` is disclosed behind a disclosure.
    case needsFullDiskAccess(path: String)

    /// Still missing after a Check Again — escalates to quit-and-reopen copy.
    case needsFullDiskAccessStillMissing(path: String)

    /// The load succeeded; an honest cold-start "preparing your board" loading
    /// state. NOT a board and NOT "all caught up" — the board is the next slice.
    case connectedPreparingBoard

    /// A non-FDA failure; the view derives per-family copy from the case.
    case failed(StowerStartupFailure)

    /// Whether the current state is one of the two Full Disk Access states.
    ///
    /// Lets the model escalate a repeat FDA failure to the still-missing copy.
    internal var isAwaitingFullDiskAccess: Bool {
        switch self {
        case .needsFullDiskAccess, .needsFullDiskAccessStillMissing:
            return true
        case .checkingModel, .modelUnavailable, .needsLicense, .checkingLicense, .checkingMessages,
            .connectedPreparingBoard, .failed:
            return false
        }
    }
}
