import Foundation

/// The board's one dismissible bottom-banner slot, driven by license/trial
/// state (§What → "Money-moment states", F2/F3).
///
/// Exactly one banner (or none) is shown at a time — never stacked. `.none`
/// covers both the licensed case and the expired case (the paywall screen
/// owns messaging once the trial has ended).
internal enum StowerBoardBannerState: Sendable, Equatable {
    /// No banner: licensed, or the trial has expired (paywall owns that case).
    case none

    /// The quiet, dismissible "Free trial · ends <date>" status (current
    /// `StowerTrialBadgeView` behavior).
    case trialBadge(expiry: Date)

    /// F3 — the trial ends within a day; escalates with a Buy nudge. Persists
    /// through the final day (not dismissible, unlike the earlier trial badge).
    case buyNudge(expiry: Date)

    /// F2 — the user tapped Buy and returned to the app this session with no
    /// license stored yet; offers to jump to the key-entry screen.
    case enterKey

    /// Computes the banner state from the current trial/session facts.
    ///
    /// - Parameters:
    ///   - hasStoredLicense: Whether a license is already persisted (→ `.none`).
    ///   - boughtThisSession: Whether `openCheckout()` was tapped and the app
    ///     has since returned to the foreground with no license stored (F2).
    ///   - trialBadge: The active trial's badge data, or `nil` (expired/none).
    ///   - now: The instant to evaluate the F3 threshold against.
    /// - Returns: The single banner state to render for the current facts.
    internal static func resolve(
        hasStoredLicense: Bool,
        boughtThisSession: Bool,
        trialBadge: StowerTrialBadge?,
        now: Date
    ) -> StowerBoardBannerState {
        guard !hasStoredLicense else { return .none }
        if boughtThisSession { return .enterKey }
        guard let trialBadge else { return .none }
        let daysRemaining = trialBadge.expiry.timeIntervalSince(now) / Self.secondsPerDay
        return daysRemaining <= Self.buyNudgeThresholdDays
            ? .buyNudge(expiry: trialBadge.expiry)
            : .trialBadge(expiry: trialBadge.expiry)
    }

    /// F3 threshold: one day or less of trial remaining (highest intent, least nag).
    ///
    /// `internal` (not `private`) so `StowerRootView.scheduleTrialExpiryRecheckIfNeeded`
    /// can schedule a re-render at this same threshold — the single source of truth
    /// for "how soon before expiry does F3 start" lives here, not duplicated there.
    internal static let buyNudgeThresholdDays: Double = 1
    private static let secondsPerDay: Double = 24 * 60 * 60
}
