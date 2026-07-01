import AppKit
import SwiftUI

/// `StowerRootView`'s licensing/trial/banner concern: the F2/F3 board banner
/// state, activation, the consent-card and trial-expiry background timers, and
/// the Lemon Squeezy checkout launch.
///
/// Split into this extension (the same split-across-files posture as
/// `StowerBoardViewModel`'s `Drafts`/`Load`/`Triage` extensions) so the primary
/// file stays focused on the screen switch and view composition. All `@State`
/// this extension reads/writes is declared `internal` on the primary type,
/// since a stored property can't live in an extension.
extension StowerRootView {
    /// The board's current bottom-banner state (F2/F3), recomputed on every
    /// render from the cached trial badge, the F2 session flag, and whether the
    /// pre-F3 badge has been dismissed.
    ///
    /// The board is reached only when licensed or on an active trial, so a nil
    /// `trialBadge` here always means licensed. Reads `bannerRecomputeTick`
    /// (unused otherwise) so the F3-threshold timer in
    /// `scheduleTrialExpiryRecheckIfNeeded` can force this to re-evaluate
    /// `Date()` against the threshold without waiting for `trialBadge` itself
    /// to change — a continuously-foregrounded session has no other event
    /// between `onAppear` and the trial's actual `expiry`.
    internal var currentBannerState: StowerBoardBannerState {
        _ = bannerRecomputeTick
        let resolved = StowerBoardBannerState.resolve(
            hasStoredLicense: trialBadge == nil,
            boughtThisSession: boughtThisSession,
            trialBadge: trialBadge,
            now: Date()
        )
        // The quiet trial badge alone (not F2/F3) honors the dismiss flag.
        if case .trialBadge = resolved, trialBannerDismissed {
            return .none
        }
        return resolved
    }

    /// Activates `key` via the model, then — on success — fires the F1
    /// confirmation alert (the model's `.activate` reruns startup into the
    /// board).
    ///
    /// Success is keyed off `activate(key:)`'s return value, NOT the rerun's
    /// terminal state: a successful activation persists the license before the
    /// rerun, and that rerun can legitimately stop short of the board (FDA
    /// onboarding, `StowerModelUnavailableView`). The user still paid and
    /// activated, so F1 must fire on every success path — the alert is attached
    /// at `StowerRootView.body`'s root, so it presents over whichever screen
    /// the rerun lands on.
    ///
    /// Refreshes `trialBadge` explicitly here rather than relying on the board's
    /// `onAppear` to refire: a mid-trial activation (F2/gear-menu entry) commits
    /// `.needsLicense` first, so the board view is torn down and SwiftUI *should*
    /// re-run `onAppear` on return — but that reconstruction is an implementation
    /// detail, not a contract, and the stored license already flips `trialBadge()`
    /// to `nil` at this point, so a direct read here is the correct fix either way.
    internal func activate(key: String) {
        Task {
            guard await model.activate(key: key) else { return }
            await model.activeRun?.value
            trialBadge = model.trialBadge()
            licenseKey = ""
            boughtThisSession = false
            showPurchaseThanks = true
        }
    }

    /// Jumps to the key-entry screen from the board (gear menu / F2 banner,
    /// JC5) without waiting for the trial to expire.
    internal func jumpToKeyEntry() {
        model.showLicenseEntry()
    }

    /// Schedules the analytics consent card to appear after ~60 seconds of
    /// foreground board time, shown at most once ever (JC7).
    ///
    /// The countdown is cancelled when the app backgrounds or the board screen
    /// leaves the hierarchy, and rescheduled on return — so the card honors
    /// *foreground board* time, never firing while backgrounded or off-board.
    /// The shown-flag is stored in `UserDefaults` by `StowerDiagnosticsConsent` so
    /// the card never reappears after the user has made a choice.
    internal func scheduleConsentCardIfNeeded() {
        guard !consent.hasShownDisclosure else { return }
        consentCardTask?.cancel()
        consentCardTask = Task { @MainActor in
            try? await Task.sleep(for: Self.consentCardDelay)
            guard !Task.isCancelled, !consent.hasShownDisclosure else { return }
            consent.markDisclosureShown()
            withAnimation { showConsentCard = true }
        }
    }

    /// Sleeps until the F3 threshold (`expiry - 1 day`, if still ahead) and then
    /// `expiry` itself, re-rendering the banner at the former and re-checking the
    /// license at the latter — so a continuously-foregrounded session (never
    /// backgrounded/foregrounded again) still shows the F3 buy nudge on schedule
    /// and routes to the paywall the moment the 7-day trial elapses, instead of
    /// only on the next `didBecomeActive`.
    ///
    /// A no-op when licensed (`trialBadge == nil`) or already past expiry —
    /// the next foreground/appear re-check handles that case. Re-armed on
    /// every appear/foreground so both sleep durations are always fresh.
    internal func scheduleTrialExpiryRecheckIfNeeded() {
        trialExpiryTask?.cancel()
        guard let expiry = trialBadge?.expiry, expiry > Date() else { return }
        let f3Threshold = expiry.addingTimeInterval(
            -Self.secondsPerDay * StowerBoardBannerState.buyNudgeThresholdDays
        )
        trialExpiryTask = Task { @MainActor in
            if f3Threshold > Date() {
                try? await Task.sleep(for: .seconds(f3Threshold.timeIntervalSinceNow))
                guard !Task.isCancelled else { return }
                bannerRecomputeTick = Date()
            }
            try? await Task.sleep(for: .seconds(expiry.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            await model.refreshLicenseIfOnBoard()
            trialBadge = model.trialBadge()
        }
    }

    /// Opens the static Lemon Squeezy checkout URL and sets the F2 session flag.
    ///
    /// A return to the app with no license yet stored then shows the "Enter
    /// license key" banner. A no-op if the configured URL won't build (fails
    /// closed rather than opening a malformed URL), or if the browser launch
    /// itself fails — the F2 flag and `checkoutOpened` funnel event must not
    /// record a checkout that never actually opened.
    internal func openCheckout() {
        guard let url = URL(string: StowerLicenseConfig.resolved.checkoutURL) else { return }
        guard NSWorkspace.shared.open(url) else { return }
        boughtThisSession = true
        analyticsReporter.report(.checkoutOpened)
    }

    /// The delay before showing the analytics consent card after the board appears.
    ///
    /// ~60 seconds of foreground board time (JC7 — after the user has seen value,
    /// not at startup or at the FDA permission cliff).
    fileprivate static let consentCardDelay: Duration = .seconds(60)

    /// Seconds per day, for computing the F3 threshold instant from
    /// `StowerBoardBannerState.buyNudgeThresholdDays` in
    /// `scheduleTrialExpiryRecheckIfNeeded`.
    fileprivate static let secondsPerDay: Double = 24 * 60 * 60
}
