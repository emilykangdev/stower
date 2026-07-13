import Foundation

/// `StowerStartupModel`'s funnel-analytics emission (Eng F1/F2).
///
/// Split into this extension (the same split-across-files posture as
/// `StowerBoardViewModel`'s `Drafts`/`Load`/`Triage` extensions) so the primary
/// file stays focused on the startup state machine itself. All state this
/// extension reads/writes (`wasAwaitingMessagesAccess`, `boardReachedThisLaunch`,
/// `trialStartedThisLaunch`, `hardwareCheckedThisRun`, `reporter`) is declared
/// `internal` on the primary type, since a stored property can't live in an
/// extension.
extension StowerStartupModel {
    /// Emits the appropriate funnel analytics event for a committed state.
    ///
    /// Uses the `wasAwaitingMessagesAccess` latch so `messages_access_resolved`
    /// fires exactly once per run that entered a messages-access state, and the
    /// `boardReachedThisLaunch` flag so `board_reached` fires once per launch.
    /// Driven off `commit` (not adjacent-state matching or `onAppear`) per
    /// Eng F1/F2.
    ///
    /// `hardware_checked` fires from every TERMINAL state a `runStartup` run can
    /// reach — `.modelUnavailable` (false) or any of `.needsLicense`,
    /// `.connectedPreparingBoard`, `.needsMessagesAccess(StillMissing)`, `.failed`
    /// (true, since all four are only reachable once the model preflight AND
    /// `loadDebtBoard` agree the model is available) — never from the
    /// `.checkingMessages` commit itself, which is optimistic UI-only
    /// (`emitsFunnelEvent: false` in `route(licenseState:...)`): that commit
    /// happens BEFORE `loadDebtBoard` runs, and that load can still throw
    /// `.modelUnavailable`, so reporting `true` there would conflict with a
    /// `false` reported moments later for the same run.
    ///
    /// `messages_access_resolved(granted:true)` fires only at
    /// `.connectedPreparingBoard` — NOT at `.checkingMessages`. The board is
    /// entered optimistically: `.checkingMessages` commits before
    /// `loadDebtBoard` runs, and that load can still throw
    /// `messagesAccessMissing` and route to `.needsMessagesAccessStillMissing`.
    /// Resolving at `.checkingMessages` would record a false "granted" for every
    /// user who returned from the picker without granting. Reaching the board
    /// is the only proof access actually works. Denial is measured as
    /// `messages_access_requested` without a subsequent
    /// `messages_access_resolved`.
    internal func emitFunnelEvent(for state: StowerStartupState) {
        switch state {
        case .modelUnavailable(let reason):
            emitHardwareCheckedIfNeeded(supported: false, reason: "\(reason)")

        case .needsLicense(let error):
            // Model was available; the license read is what routed here.
            emitHardwareCheckedIfNeeded(supported: true, reason: nil)
            reporter.report(.paywallReached(error: error))

        case .needsMessagesAccess:
            emitHardwareCheckedIfNeeded(supported: true, reason: nil)
            reporter.report(.messagesAccessRequested)
            wasAwaitingMessagesAccess = true

        case .connectedPreparingBoard:
            emitHardwareCheckedIfNeeded(supported: true, reason: nil)
            resolveMessagesAccessIfNeeded()
            emitBoardReachedIfNeeded()

        case .failed, .needsMessagesAccessStillMissing:
            emitHardwareCheckedIfNeeded(supported: true, reason: nil)

        case .checkingModel, .checkingMessages:
            break
        }
    }

    /// Emits `hardware_checked` at most once per run via `hardwareCheckedThisRun`.
    ///
    /// Every terminal-state branch in `emitFunnelEvent(for:)` calls this, but only
    /// one of them ever actually commits per run — the latch is defense-in-depth,
    /// not the primary mechanism (that's the `emitsFunnelEvent: false` on the
    /// optimistic `.checkingMessages` commit removing the double-report at its
    /// source). Outside `runStartup` (e.g. `handleBoardFailure`, which commits
    /// after `board_reached` already fired for this launch) the latch was reset by
    /// the last `runStartup` and so still allows that separate, legitimate report.
    internal func emitHardwareCheckedIfNeeded(supported: Bool, reason: String?) {
        guard !hardwareCheckedThisRun else { return }
        hardwareCheckedThisRun = true
        reporter.report(.hardwareChecked(supported: supported, reason: reason))
    }

    /// Emits `messages_access_resolved(granted:true)` when the awaiting latch is set.
    ///
    /// Fires once per run that entered a `needsMessagesAccess` state, only after
    /// the board is reached (access proven); clears the latch afterward so it
    /// cannot double-fire.
    internal func resolveMessagesAccessIfNeeded() {
        guard wasAwaitingMessagesAccess else { return }
        reporter.report(.messagesAccessResolved(granted: true))
        wasAwaitingMessagesAccess = false
    }

    /// Emits `board_reached` at most once per launch via the `boardReachedThisLaunch` latch.
    internal func emitBoardReachedIfNeeded() {
        guard !boardReachedThisLaunch else { return }
        reporter.report(.boardReached)
        boardReachedThisLaunch = true
    }

    /// Emits `trial_started` exactly once across the trial's whole life — the
    /// single launch whose license read seeds the trial clock — not once per
    /// launch that merely observes an already-running trial. `isFirstObservation`
    /// carries that distinction from `StowerLicenseGating.isFirstTrialObservation`;
    /// `trialStartedThisLaunch` still guards a same-launch Check Again from
    /// double-firing (the clock is seeded by the first run, so a second run in
    /// the same launch would otherwise see `isFirstObservation` flip to `false`
    /// correctly, but the guard stays as a defense-in-depth per-launch latch).
    internal func emitTrialStartedIfNeeded(
        for licenseState: StowerLicenseState,
        isFirstObservation: Bool
    ) {
        guard case .trial = licenseState, isFirstObservation, !trialStartedThisLaunch else {
            return
        }
        reporter.report(.trialStarted)
        trialStartedThisLaunch = true
    }
}
