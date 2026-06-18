import Foundation
import Observation

/// The presentation phase the board view switches on.
///
/// Distinct from the loaded data: `board` holds the rows, `phase` says which
/// surface to show. `.error` is the board-level "something went wrong" (total
/// refresh failure, I9) — NOT a thrown `StowerStartupFailure`, which routes to
/// onboarding via `onFailure`.
internal enum StowerBoardPhase: Sendable, Equatable {
    /// Cold start / in-flight: spinner with a first-run time expectation.
    case preparing

    /// A loaded board with at least one row in some lens.
    case rows

    /// A completed pass with nothing to show (empty snapshot or empty lenses).
    case caughtUp

    /// A completed pass that judged nothing despite having records — retryable.
    case error
}

/// Drives the debt-board surface: load, refresh, preset, and direction.
///
/// Mirrors `StowerStartupModel`'s discipline — a generation token on `load()` so a
/// stale preset's late result can't overwrite a newer board (I13), and the same
/// `CancellationError`-is-a-no-op / `StowerStartupFailure`-routes contract. `load`
/// and `refresh` are distinct engine calls: `load` serves cached rows at structural
/// speed; `refresh` runs the background model pass and resolves the cold-start
/// "preparing" state per the `StowerBoardRefreshOutcome` (I6/I6b/I9).
@MainActor
@Observable
internal final class StowerBoardViewModel {
    /// The presentation phase the view renders.
    internal private(set) var phase: StowerBoardPhase = .preparing

    /// The loaded board; the view reads the lens for `direction`.
    internal private(set) var board: StowerBoardModel?

    /// Whether a background refresh is in flight (disables the refresh control).
    internal private(set) var isRefreshing = false

    /// The visible day-filter preset; changing it re-loads (I8).
    internal private(set) var selectedPreset: StowerDayPreset = .default

    /// The visible lens; changing it re-queries nothing (I7).
    internal var direction: StowerBoardDirection = .neglected

    /// The last-synced Contacts authorization, as *observed* state.
    ///
    /// So SwiftUI recomputes the banner when it changes (a live read of
    /// `contacts.authorization` wouldn't). Refreshed wherever authorization can move:
    /// on appear, after an in-app prompt resolves (grant *or* deny), and on app
    /// re-activation.
    internal private(set) var contactsAuthorization: StowerContactsAuthorization

    /// Bumps whenever Contacts access is *lost* (authorized → not), so the board view
    /// dismisses an open thread before its captured row's resolved name can linger.
    internal private(set) var contactsRevocationToken = 0

    private let dataSource: any StowerBoardDataSource
    private let contacts: StowerContactsAccess
    private let settings: StowerSystemSettingsOpener
    private let opener: StowerMessagesLinkOpener
    private let onFailure: @MainActor (StowerStartupFailure) -> Void
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Backoff between `.coalesced` retries while cold start is unresolved, so the
    /// re-issue waits for the other in-flight pass instead of busy-spinning.
    private static let coalesceRetryDelay: Duration = .milliseconds(400)

    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var contactsTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var refreshGeneration = 0
    private var hasResolvedColdStart = false
    private var isRequestingContacts = false
    private var awaitingContactsRecovery = false

    /// Creates the board view-model.
    ///
    /// - Parameters:
    ///   - dataSource: The app-owned board boundary (live adapter or a spy).
    ///   - contacts: The Contacts-access wrapper; defaults to a denied no-op so
    ///     tests/previews never prompt. Production injects the real access from the
    ///     composition, so a first-run grant flips rows to names on the next load.
    ///   - settings: Opens the System Settings → Contacts pane when access was
    ///     denied (the system never re-prompts; Settings is the only recovery).
    ///   - opener: The Messages deep-link opener handed to thread view-models.
    ///   - onFailure: Routes a board failure back to the startup model.
    ///   - clock: Supplies `now`; injectable so tests are deterministic.
    ///   - sleep: The coalesced-retry backoff; injectable so tests need no real
    ///     wall-clock wait. Throwing, because `Task.sleep(for:)` throws.
    internal init(
        dataSource: any StowerBoardDataSource,
        contacts: StowerContactsAccess = .denied,
        settings: StowerSystemSettingsOpener = StowerSystemSettingsOpener(),
        opener: StowerMessagesLinkOpener = StowerMessagesLinkOpener(),
        onFailure: @escaping @MainActor (StowerStartupFailure) -> Void,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.dataSource = dataSource
        self.contacts = contacts
        self.settings = settings
        self.opener = opener
        self.onFailure = onFailure
        self.clock = clock
        self.sleep = sleep
        contactsAuthorization = contacts.authorization
    }

    /// Runs the launch sequence on appear: load the cached board, then refresh.
    ///
    /// Called once per board appearance (SwiftUI's `.task`), so re-entering the
    /// board after an FDA-recovery round-trip reloads. A redundant call is safe:
    /// `load()` supersedes via its generation token and `refresh()` is guarded by
    /// `isRefreshing`.
    internal func onAppear() {
        syncContactsAuthorization()
        load()
        refresh()
    }

    /// Mirrors the live Contacts authorization into observed state.
    ///
    /// So the banner's visibility and label recompute. Cheap (a bare status read);
    /// call it wherever authorization can have changed.
    private func syncContactsAuthorization() {
        contactsAuthorization = contacts.authorization
    }

    /// Whether to show the "show real names" banner above the board.
    ///
    /// Visible exactly when the board has rows to label and Contacts is not
    /// authorized — so an unmatched board always carries a durable, in-context way to
    /// grant access, instead of relying on a one-shot system prompt that, once
    /// denied, never returns. Empty / caught-up / preparing boards show nothing.
    internal var showsContactsAccessBanner: Bool {
        phase == .rows && contactsAuthorization != .authorized
    }

    /// The banner button's label, matched to the action `resolveContactsAccess` will
    /// take: a never-asked board can be prompted in-app; a denied one must go to
    /// Settings, so the label sets that expectation before the tap.
    internal var contactsBannerActionTitle: String {
        switch contactsAuthorization {
        case .denied: return "Open Settings"
        default: return "Show names"
        }
    }

    /// Drives the banner's button: raise the system prompt, or route to Settings.
    ///
    /// `.notDetermined` raises the one system prompt (non-blocking) and, on a fresh
    /// grant, reloads so the per-load resolver rebuilds and rows flip to names with
    /// no relaunch; re-taps while a request is in flight are ignored so a double-tap
    /// can't fan out into duplicate requests. `.denied` (or restricted) can't be
    /// re-prompted, so it opens System Settings → Contacts and arms a recovery
    /// reload for when the user returns (`onAppBecameActive`). `.authorized` is a
    /// no-op (the banner is already hidden).
    internal func resolveContactsAccess() {
        switch contacts.authorization {
        case .authorized:
            return
        case .denied:
            awaitingContactsRecovery = true
            settings.openPane(.contacts)
        case .notDetermined:
            guard !isRequestingContacts else { return }
            isRequestingContacts = true
            contactsTask = Task { [weak self] in
                guard let self else { return }
                defer { isRequestingContacts = false }
                let granted = await contacts.requestAccessIfNeeded()
                // Reflect the outcome (grant *or* deny) so the banner updates: a deny
                // flips the label to "Open Settings"; a grant reloads into names.
                syncContactsAuthorization()
                guard granted, !Task.isCancelled else { return }
                load()
            }
        }
    }

    /// Re-checks Contacts when the app returns to the foreground.
    ///
    /// Switching apps does not re-run the board's `.task`, and a Settings change
    /// can't notify us, so this is where a foreground Contacts change is reconciled.
    /// We reload when authorization *changed* while away — picking up a grant made in
    /// Settings (names appear) **and** dropping already-resolved names when access
    /// was revoked (a privacy leak otherwise) — or when we'd explicitly sent the user
    /// to recover access (so a denied→still-denied return refreshes to handles too).
    internal func onAppBecameActive() {
        let previous = contactsAuthorization
        syncContactsAuthorization()
        // Access lost while away — signal the view to dismiss an open thread so its
        // captured row's resolved name can't outlive the grant.
        if previous == .authorized, contactsAuthorization != .authorized {
            contactsRevocationToken += 1
        }
        let wasAwaitingRecovery = awaitingContactsRecovery
        awaitingContactsRecovery = false
        if wasAwaitingRecovery || contactsAuthorization != previous {
            load()
        }
    }

    /// Selects a new day preset, re-loading at the new threshold (I8).
    ///
    /// Shows `.preparing` immediately so the visible rows never lag behind the
    /// selected filter while the new load is in flight — the rows on screen always
    /// match the chosen threshold.
    internal func selectPreset(_ preset: StowerDayPreset) {
        guard preset != selectedPreset else { return }
        selectedPreset = preset
        phase = .preparing
        load()
    }

    /// Re-attempts the model pass after a board-level error.
    internal func retry() {
        phase = .preparing
        refresh()
    }

    /// Cancels in-flight work when the board view disappears.
    ///
    /// Supersedes BOTH generations so a cancellation-ignoring load or refresh that
    /// completes after disappearance is discarded by the generation guards (it
    /// can't apply stale board state or route a failure into onboarding once the
    /// board is gone). Also resets `isRefreshing` so the next `onAppear` can start a
    /// fresh refresh even if the cancelled task hasn't finished unwinding yet —
    /// without that reset a cancelled-but-not-yet-exited refresh would keep
    /// `isRefreshing` true and strand cold start in `.preparing`.
    internal func cancel() {
        loadTask?.cancel()
        refreshTask?.cancel()
        contactsTask?.cancel()
        loadGeneration += 1
        refreshGeneration += 1
        isRefreshing = false
    }

    /// Builds a thread view-model for a tapped row, sharing the data source/opener.
    internal func makeThreadViewModel(for row: StowerBoardRow) -> StowerThreadViewModel {
        StowerThreadViewModel(
            row: row,
            dataSource: dataSource,
            opener: opener,
            onFailure: onFailure,
            clock: clock
        )
    }

    /// The in-flight load/refresh/contacts tasks, exposed so tests can await them.
    internal var loadTaskHandle: Task<Void, Never>? { loadTask }
    internal var refreshTaskHandle: Task<Void, Never>? { refreshTask }
    internal var contactsTaskHandle: Task<Void, Never>? { contactsTask }

    /// Loads the cached board under a fresh generation token (I13).
    internal func load() {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.runLoad(generation: generation)
        }
    }

    /// Runs the background refresh loop, guarded against user re-entry.
    internal func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            await self?.runRefreshLoop(generation: generation)
        }
    }

    private var config: StowerStartupDebtConfig {
        StowerStartupDebtConfig(
            unansweredForDays: selectedPreset.days,
            minimumReciprocity: StowerStartupDebtConfig.appDefault.minimumReciprocity,
            ghostGateThreshold: StowerStartupDebtConfig.appDefault.ghostGateThreshold
        )
    }

    private func runLoad(generation: Int) async {
        do {
            let model = try await dataSource.loadBoard(config: config, now: clock())
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
    private func runRefreshLoop(generation: Int) async {
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
