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

    /// The trial has ended (or is untried) and no license is stored; the
    /// paywall/key-entry screen shows, carrying the last activation error (if
    /// any) so a re-render after a failed attempt still shows it.
    case needsLicense(StowerLicenseGateError?)

    /// Model is available; attempting the board load behind the permission gate.
    case checkingMessages

    /// Messages access has never been granted; the picker's own pre-navigation
    /// already shows the target, so there's nothing to disclose yet (JC3).
    case needsMessagesAccess

    /// Still missing after a Check Again; `detail` describes what failed so the
    /// disclosure can explain a stale/revoked bookmark.
    case needsMessagesAccessStillMissing(detail: String)

    /// The load succeeded; an honest cold-start "preparing your board" loading
    /// state. NOT a board and NOT "all caught up" — the board is the next slice.
    case connectedPreparingBoard

    /// A non-messages-access failure; the view derives per-family copy from the case.
    case failed(StowerStartupFailure)

    /// Whether the current state is one of the two Messages-access states.
    ///
    /// Lets the model escalate a repeat messages-access failure to the
    /// still-missing copy.
    internal var isAwaitingMessagesAccess: Bool {
        switch self {
        case .needsMessagesAccess, .needsMessagesAccessStillMissing:
            return true
        case .checkingModel, .modelUnavailable, .needsLicense, .checkingMessages,
            .connectedPreparingBoard, .failed:
            return false
        }
    }
}
