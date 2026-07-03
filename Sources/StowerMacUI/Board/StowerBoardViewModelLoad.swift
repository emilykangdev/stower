import Foundation

/// The board view-model's load/refresh state machine: the generation-guarded cached
/// load (I13), the background refresh loop (I6/I6b/I9), and the outcome handlers that
/// resolve the cold-start `.preparing` state.
///
/// Split into this extension (the same split-across-files posture as the draft and
/// triage surfaces) so the primary file holds the stored state and the user-facing
/// entry points. These methods own the writes to `phase` / `board` / `isRefreshing`.
extension StowerBoardViewModel {
    /// The in-flight load/refresh/contacts/triage tasks, exposed so tests can await them.
    internal var loadTaskHandle: Task<Void, Never>? { loadTask }
    internal var refreshTaskHandle: Task<Void, Never>? { refreshTask }
    internal var contactsTaskHandle: Task<Void, Never>? { contactsTask }
    internal var triageTaskHandle: Task<Void, Never>? { triageTask }

    /// The debt-board config for the current preset.
    internal var config: StowerStartupDebtConfig {
        StowerStartupDebtConfig(
            unansweredForDays: selectedPreset.days,
            minimumReciprocity: StowerStartupDebtConfig.appDefault.minimumReciprocity,
            ghostGateThreshold: StowerStartupDebtConfig.appDefault.ghostGateThreshold
        )
    }

    /// Runs the cached load under a generation token, merging drafts before exposing
    /// rows; a superseded generation drops out, a failure routes via `onFailure`.
    internal func runLoad(generation: Int) async {
        do {
            let model = try await dataSource.loadBoard(config: config, now: clock())
            guard generation == loadGeneration else { return }
            // Merge persisted drafts BEFORE exposing rows. Once rows are interactive the
            // user can open the composer (setting `composerKey`), and `mergeDrafts` skips
            // `composerKey` — so a draft merged after rows appear could be skipped and
            // then overwritten by the first edit. Merging first closes that window.
            await mergeDrafts(generation: generation)
            guard generation == loadGeneration else { return }
            applyLoaded(model)
        } catch is CancellationError {
            // Superseded / dismissed — never a failure.
        } catch let failure as StowerStartupFailure {
            guard generation == loadGeneration else { return }
            onFailure(failure)
        } catch {
            guard generation == loadGeneration else { return }
            onFailure(.unexpected)
        }
    }

    private func applyLoaded(_ model: StowerBoardModel) {
        board = model
        if !model.isEmpty {
            phase = .rows
        } else if hasResolvedColdStart {
            phase = .caughtUp
        } else {
            phase = .preparing
        }
    }

    /// Runs the refresh loop: re-issue on `.incomplete`, resolve on `.completed`,
    /// exit on `.coalesced`.
    ///
    /// The loop IS the re-issue, so the `isRefreshing` guard never blocks it;
    /// cancellation breaks out.
    internal func runRefreshLoop(generation: Int) async {
        // Generation-guarded so a superseded (cancelled) run's late exit can't clear
        // a newer refresh's `isRefreshing` flag.
        defer {
            if generation == refreshGeneration { isRefreshing = false }
        }
        do {
            while true {
                let outcome = try await dataSource.refreshJudgments(config: config, now: clock())
                // A superseded refresh (cancel / a newer refresh) must not apply its
                // outcome over a newer one, mirroring the load path's generation guard.
                guard generation == refreshGeneration else { return }
                if try await handleRefreshOutcome(outcome, generation: generation) == false {
                    return
                }
            }
        } catch {
            routeRefreshFailure(error, generation: generation)
        }
    }

    /// Routes a refresh failure, dropping a `CancellationError` (superseded /
    /// dismissed — never a failure) and any stale-generation throw.
    private func routeRefreshFailure(_ error: Error, generation: Int) {
        guard !(error is CancellationError), generation == refreshGeneration else { return }
        onFailure((error as? StowerStartupFailure) ?? .unexpected)
    }

    /// Acts on one refresh outcome; returns whether the loop should re-issue.
    ///
    /// The caller has already confirmed `generation` is current before calling, so
    /// `applyCompleted` is safe; the coalesced path re-checks after its backoff so a
    /// superseded refresh stops re-issuing.
    private func handleRefreshOutcome(
        _ outcome: StowerBoardRefreshOutcome,
        generation: Int
    ) async throws -> Bool {
        switch outcome {
        case .coalesced:
            // Another pass is running. Once cold start is resolved, keep the current
            // board (neither clear nor reload). But while still preparing, the other
            // pass's summary goes to ITS caller, not us — so back off and re-issue
            // rather than strand the spinner.
            if hasResolvedColdStart || Task.isCancelled { return false }
            try await sleep(Self.coalesceRetryDelay)
            return generation == refreshGeneration
        case .completed(let reloadNeeded, let anyJudged, let hadRecords):
            applyCompleted(reloadNeeded: reloadNeeded, anyJudged: anyJudged, hadRecords: hadRecords)
            return false
        case .incomplete:
            return !Task.isCancelled && generation == refreshGeneration
        }
    }

    private func applyCompleted(reloadNeeded: Bool, anyJudged: Bool, hadRecords: Bool) {
        let wasColdStart = !hasResolvedColdStart
        hasResolvedColdStart = true
        if anyJudged {
            // Reload when this pass changed rows, OR on the first cold-start
            // resolution while the board is still the empty cold load: if we
            // coalesced against another pass, that pass's writes were reported to
            // ITS caller (changedCount 0 for us), so without this we'd resolve to a
            // false "all caught up" over a now-warm cache we never re-read.
            if reloadNeeded || (wasColdStart && (board?.isEmpty ?? true)) {
                load()
            } else {
                phase = (board?.isEmpty ?? true) ? .caughtUp : .rows
            }
        } else if hadRecords {
            phase = .error
        } else {
            phase = .caughtUp
        }
    }
}
