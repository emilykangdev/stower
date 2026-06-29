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

    /// The model is available but the license check did not pass; the context
    /// selects the entry-screen variant (trial-ended / upgrade / connect / retry).
    case needsLicense(StowerLicenseEntryContext)

    /// Resolving the license with the server (mint-on-first-run or revalidate an
    /// existing lease). The spinner shows a neutral "Loading Stower…" because
    /// trial-vs-paid is unknown until the server replies — a cleared lease can still
    /// belong to a paid device.
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
