import Foundation
import Observation

/// Drives the messages-access-first startup flow and owns the single
/// `StowerStartupState` the root view renders.
///
/// `start()` runs the flow once; `checkAgain()` reruns it. The flow is re-entrant:
/// each run cancels the one in flight, takes a fresh generation token, and any
/// stale completion is discarded by the token — so an overlapping Check Again
/// never lets an older result overwrite a newer one. A `CancellationError` (from
/// the load or the minimum-display delay) never routes to `.failed`; it is a
/// superseded run, not a failure.
@MainActor
@Observable
internal final class StowerStartupModel {
    /// The state the root view switches on.
    internal private(set) var state: StowerStartupState = .checkingModel

    private let provider: any StowerStartupProviding
    private let config: StowerStartupDebtConfig
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onCommit: (@MainActor @Sendable (StowerStartupState) -> Void)?

    /// The license gate and clock.
    ///
    /// `internal` (not `private`) so the `StowerStartupModelLicenseEntry.swift`
    /// extension's `showLicenseEntry()`/`dismissLicenseEntry()` can read them
    /// without widening access beyond the module.
    internal let licenseGate: any StowerLicenseGating
    internal let clock: @Sendable () -> Date

    /// The analytics reporter.
    ///
    /// `internal` (not `private`) so `StowerStartupModelAnalytics.swift`'s
    /// `emitFunnelEvent(for:)` and its helpers can report funnel events without
    /// widening access beyond the module.
    internal let reporter: any StowerAnalyticsReporting
    /// `internal` so the `StowerStartupModelLicenseEntry.swift` extension can
    /// cancel/bump the in-flight run when jumping to or out of key entry.
    internal var inFlight: Task<Void, Never>?
    internal var generation = 0

    /// `true` while awaiting messages access; cleared after `messages_access_resolved` fires.
    ///
    /// Drives this latch so `checkAgain()` re-runs don't double-fire
    /// `messages_access_requested`. `internal` so
    /// `StowerStartupModelAnalytics.swift` can read/clear it.
    internal var wasAwaitingMessagesAccess = false

    /// Guards `board_reached` to one emission per launch (per-launch semantics).
    /// `internal` so `StowerStartupModelAnalytics.swift` can read/set it.
    internal var boardReachedThisLaunch = false

    /// Guards `trial_started` to one emission per launch (per-launch semantics).
    /// `internal` so `StowerStartupModelAnalytics.swift` can read/set it.
    internal var trialStartedThisLaunch = false

    /// Guards `hardware_checked` to one emission per RUN (reset at the top of
    /// every `runStartup`, unlike the per-launch latches above).
    ///
    /// `.checkingMessages`/`.needsLicense` report `supported: true` optimistically
    /// before `loadDebtBoard` runs, but that load can still throw
    /// `.modelUnavailable` and route the same run to `supported: false` — without
    /// this latch, one run would report the metric twice with conflicting
    /// verdicts. The FIRST commit in a run wins; a Check Again is a fresh run
    /// (fresh `runStartup` call) and may report again. `internal` so
    /// `StowerStartupModelAnalytics.swift` can read/set it.
    internal var hardwareCheckedThisRun = false

    /// `true` while an `activate(key:)` call is in flight.
    ///
    /// Guards against a duplicate `/activate` network call from a rapid
    /// double-submit (double-click, or Return then clicking Activate) — Lemon
    /// Squeezy's `activation_limit` is a finite, server-enforced resource, so
    /// two concurrent calls for one real purchase must not both consume a
    /// slot. Exposed so the key-entry view can disable Activate while true.
    internal private(set) var isActivating = false

    /// Whether the Back affordance is offered on `StowerLicenseEntryView`.
    ///
    /// `true` only while the key-entry screen was opened VOLUNTARILY mid-trial
    /// (JC5) and the user can still return; NOT set on an expiry paywall (no
    /// board to go back to). Set by `showLicenseEntry()`, cleared by
    /// `beginRun()`/`dismissLicenseEntry()`. `internal` (settable) so the
    /// `StowerStartupModelLicenseEntry.swift` extension owns those two methods.
    internal var licenseEntryIsDismissible = false

    /// Minimum time the checking state stays up, so a fast result doesn't flash.
    private static let minimumCheckingDisplay: Duration = .milliseconds(400)

    /// Creates the startup model.
    ///
    /// - Parameters:
    ///   - provider: The startup boundary (the real adapter in production, a fake
    ///     in tests).
    ///   - licenseGate: The license seam (the real Lemon-Squeezy-backed
    ///     `StowerLemonSqueezyLicenseGate` in production, a fake in tests). No
    ///     default — a "has license" default would ship a paywall bypass.
    ///   - config: The debt-board knobs passed to every load.
    ///   - clock: Supplies `now`; injectable so tests are deterministic.
    ///   - sleep: The minimum-display delay; injectable so tests need no real
    ///     wall-clock wait. Throwing, because `Task.sleep(for:)` throws.
    ///   - reporter: The analytics reporter for funnel events; defaults to a
    ///     no-op so previews and tests that don't assert on analytics emit nothing.
    ///   - onCommit: A test recorder fired with every committed state (after the
    ///     generation guard); `nil` in production.
    internal init(
        provider: any StowerStartupProviding,
        licenseGate: any StowerLicenseGating,
        config: StowerStartupDebtConfig = .appDefault,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        reporter: any StowerAnalyticsReporting = StowerNoOpAnalyticsReporter(),
        onCommit: (@MainActor @Sendable (StowerStartupState) -> Void)? = nil
    ) {
        self.provider = provider
        self.licenseGate = licenseGate
        self.config = config
        self.clock = clock
        self.sleep = sleep
        self.reporter = reporter
        self.onCommit = onCommit
    }

    /// Runs the startup flow once (initial launch).
    internal func start() {
        beginRun()
    }

    /// Reruns the same startup flow (the messages-access/failure screens' Check Again).
    internal func checkAgain() {
        beginRun()
    }

    /// Cancels any in-flight run so startup work (the real provider's database
    /// read) doesn't outlive the view — called when the root view disappears.
    ///
    /// A bumped generation makes any late completion a no-op; `start()` later
    /// begins a fresh run.
    internal func cancel() {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
    }

    /// The current run, exposed so a test can await the fire-and-forget flow.
    ///
    /// Not used by the views.
    internal var activeRun: Task<Void, Never>? { inFlight }

    /// The trial badge data for the current local license state, or `nil` when
    /// there is no active trial (licensed, or expired with no license).
    ///
    /// Pure local read via `licenseGate.licenseState(now:)`. Callers gate on
    /// this before showing the badge; the dismissal flag is NOT wired here.
    internal func trialBadge() -> StowerTrialBadge? {
        guard case .trial(let expiry) = licenseGate.licenseState(now: clock()) else { return nil }
        return StowerTrialBadge(expiry: expiry)
    }

    /// Activates `key` against Lemon Squeezy under the generation guard (I4):
    /// only the current-generation result may persist or commit a state.
    ///
    /// A no-op while a prior call is still in flight (`isActivating`) — a
    /// rapid double-submit must never fire two concurrent `/activate` calls
    /// against Lemon Squeezy's finite `activation_limit`. Also a no-op once the
    /// board has already been reached: `isActivating` clears (and the entry
    /// screen's Activate button re-enables) as soon as this call's network
    /// round-trip finishes, which can be before `beginRun()`'s rerun actually
    /// commits `.connectedPreparingBoard` — this second check closes that gap
    /// so a stray second submit in between can't consume another activation
    /// slot. Checks `state` (not `licenseGate.licenseState(now:)` again) so it
    /// never double-consumes the license gate's own read for this call.
    ///
    /// On `.activated`, persists the key, emits the `activated` funnel event,
    /// and reruns the startup flow so the newly-stored license routes to the
    /// board. On `.invalid` / `.couldNotReach`, commits `.needsLicense` carrying
    /// the error so the entry screen can show it — without re-emitting
    /// `hardware_checked`/`paywall_reached`: a failed re-attempt is an error
    /// re-render of a paywall visit already counted, not a new one.
    ///
    /// Returns `true` only when this call activated and persisted the key —
    /// the caller-visible success signal for the F1 confirmation. The rerun's
    /// terminal state is deliberately NOT that signal: a successful activation
    /// can still land on `.needsMessagesAccess` or `.modelUnavailable`, and the
    /// purchase confirmation must fire on every success path regardless.
    @discardableResult
    internal func activate(key: String) async -> Bool {
        guard !isActivating, state != .connectedPreparingBoard else { return false }
        isActivating = true
        defer { isActivating = false }
        let runGeneration = generation
        let outcome = await licenseGate.activate(key: key)
        guard generation == runGeneration else { return false }
        switch outcome {
        case .activated(let instanceID):
            licenseGate.persist(key: key, instanceID: instanceID)
            reporter.report(.activated)
            beginRun()
            return true
        case .invalid:
            commit(.needsLicense(.invalid), generation: runGeneration, emitsFunnelEvent: false)
            return false
        case .couldNotReach:
            commit(
                .needsLicense(.couldNotReach),
                generation: runGeneration,
                emitsFunnelEvent: false
            )
            return false
        }
    }

    /// Routes a board-load failure back into the startup screen flow.
    ///
    /// The board runs as a child `StowerBoardViewModel` rooted at
    /// `.connectedPreparingBoard`; when its load surfaces a `StowerStartupFailure`
    /// (e.g. a mid-session messages-access/source error), it re-enters onboarding
    /// here. Cancels any in-flight startup run and bumps the generation so a late
    /// startup completion can't overwrite this, then routes the failure exactly as
    /// startup would — messages-access escalation included, via the shared
    /// `route(_:wasAwaitingMessagesAccess:)`.
    internal func handleBoardFailure(_ failure: StowerStartupFailure) {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        let next = route(failure, wasAwaitingMessagesAccess: state.isAwaitingMessagesAccess)
        commit(next, generation: generation)
    }

    /// Re-checks the license without disrupting the board — called when the app
    /// returns to the foreground (e.g. back from the Lemon Squeezy checkout), so a
    /// just-entered key or an elapsed trial reflects instantly with no full
    /// startup re-run and no "Loading Stower…" flash.
    ///
    /// Pure local read (no network) — activation itself is the only network call,
    /// invoked separately via `activate(key:)` from the key-entry screen (JC3).
    /// Acts only while on the board. `.licensed` and `.trial` leave the board in
    /// place; only `.expired` routes to the paywall. The generation guard drops
    /// the result if a fresh startup run (Check Again) began during the await.
    ///
    /// The `.needsLicense` commit keeps the default `emitsFunnelEvent: true` on
    /// purpose — a mid-session expiry is a genuine forced paywall arrival, so
    /// `paywall_reached` fires exactly once (routing off the board makes every
    /// later re-check a no-op), and `hardware_checked` cannot re-fire because
    /// `hardwareCheckedThisRun` is still latched from the run that reached the
    /// board.
    internal func refreshLicenseIfOnBoard() async {
        guard state == .connectedPreparingBoard else { return }
        let runGeneration = generation
        let licenseState = licenseGate.licenseState(now: clock())
        guard generation == runGeneration, state == .connectedPreparingBoard else { return }
        if case .expired = licenseState {
            commit(.needsLicense(nil), generation: runGeneration)
        }
    }

    /// Cancels any in-flight run, bumps the generation, and starts a fresh run.
    private func beginRun() {
        inFlight?.cancel()
        licenseEntryIsDismissible = false
        generation += 1
        let runGeneration = generation
        let wasAwaitingMessagesAccess = state.isAwaitingMessagesAccess
        inFlight = Task { [weak self] in
            await self?.runStartup(
                generation: runGeneration,
                wasAwaitingMessagesAccess: wasAwaitingMessagesAccess
            )
        }
    }

    /// The flow body: preflight availability, load, route — under the generation
    /// token and the minimum-display delay.
    private func runStartup(generation: Int, wasAwaitingMessagesAccess: Bool) async {
        hardwareCheckedThisRun = false
        commit(.checkingModel, generation: generation)
        let sleepClosure = sleep
        let minimumDisplay = Self.minimumCheckingDisplay
        do {
            async let minimumDisplayDone: Void = sleepClosure(minimumDisplay)
            if case .unavailable(let reason) = await provider.modelAvailability() {
                try await minimumDisplayDone
                commit(.modelUnavailable(reason), generation: generation)
                return
            }
            // The license check is a pure local read (no network) — licensed and
            // trial both proceed straight into the board probe; only an expired
            // trial with no license routes to the paywall.
            //
            // `isFirstTrialObservation` must be read BEFORE `licenseState`: the
            // latter's trial-clock read seeds the first-launch date as a side
            // effect, so checking after would always see it as already seeded.
            let isFirstTrialObservation = licenseGate.isFirstTrialObservation(now: clock())
            let licenseState = licenseGate.licenseState(now: clock())
            guard generation == self.generation else { return }
            emitTrialStartedIfNeeded(for: licenseState, isFirstObservation: isFirstTrialObservation)
            let target = try await route(
                licenseState: licenseState,
                generation: generation,
                wasAwaitingMessagesAccess: wasAwaitingMessagesAccess
            )
            try await minimumDisplayDone
            // `target` is this run's TRUE terminal state (reached only after
            // `loadAndRoute` resolves), so `commit` here is the single place that
            // reports this run's real `hardware_checked` verdict — see the
            // `.checkingMessages` commit in `route(licenseState:...)` (which passes
            // `emitsFunnelEvent: false`) for why the optimistic UI commit must not
            // also report one.
            commit(target, generation: generation)
        } catch is CancellationError {
            // A superseded / cancelled run never routes to a failure screen.
        } catch {
            commit(.failed(.unexpected), generation: generation)
        }
    }

    /// Maps a license state to the next state: `.licensed`/`.trial` both probe
    /// the board (the trial badge is read separately by the view), `.expired`
    /// routes to the paywall/key-entry screen.
    ///
    /// The `.checkingMessages` commit here is UI-only (`emitsFunnelEvent: false`):
    /// it renders the "checking your messages" screen, but `loadAndRoute` hasn't
    /// run yet, so whether hardware is actually supported isn't known yet — that
    /// call still can throw `.modelUnavailable`. `hardware_checked` is emitted once,
    /// correctly, from the run's true terminal state in `runStartup`.
    private func route(
        licenseState: StowerLicenseState,
        generation: Int,
        wasAwaitingMessagesAccess: Bool
    ) async throws -> StowerStartupState {
        switch licenseState {
        case .licensed, .trial:
            commit(.checkingMessages, generation: generation, emitsFunnelEvent: false)
            return try await loadAndRoute(wasAwaitingMessagesAccess: wasAwaitingMessagesAccess)
        case .expired:
            return .needsLicense(nil)
        }
    }

    /// Loads the board and maps a `StowerStartupFailure` to a state; lets a
    /// `CancellationError` (and any non-app error) propagate to `runStartup`.
    private func loadAndRoute(wasAwaitingMessagesAccess: Bool) async throws -> StowerStartupState {
        do {
            try await provider.loadDebtBoard(config: config, now: clock())
            return .connectedPreparingBoard
        } catch let failure as StowerStartupFailure {
            return route(failure, wasAwaitingMessagesAccess: wasAwaitingMessagesAccess)
        }
    }

    /// Maps a typed failure to the right screen (the three-outcomes routing).
    private func route(
        _ failure: StowerStartupFailure,
        wasAwaitingMessagesAccess: Bool
    ) -> StowerStartupState {
        switch failure {
        case .messagesAccessMissing(let detail):
            return wasAwaitingMessagesAccess
                ? .needsMessagesAccessStillMissing(detail: detail)
                : .needsMessagesAccess
        case .modelUnavailable(let reason):
            return .modelUnavailable(reason)
        case .invalidConfig, .sourceMissing, .unreadable, .invalidData, .unexpected:
            return .failed(failure)
        }
    }

    /// Applies a new state only if its run is still the current generation.
    ///
    /// A stale completion can't overwrite a newer run's result. Also emits funnel
    /// analytics events via the reporter on each committed state (Eng F1), unless
    /// `emitsFunnelEvent` is `false` — used by the voluntary key-entry jump
    /// (`showLicenseEntry()`) and a failed re-activation attempt, neither of
    /// which is a genuine forced paywall arrival, so they must not re-emit
    /// `hardware_checked`/`paywall_reached`. The on-board expiry re-check
    /// (`refreshLicenseIfOnBoard()`) deliberately keeps the default `true`: a
    /// trial expiring out from under the board IS a forced paywall arrival, so
    /// `paywall_reached` fires exactly once there (`hardware_checked` stays
    /// latched by `hardwareCheckedThisRun`, set by the run that reached the
    /// board).
    ///
    /// `emitFunnelEvent(for:)` and its helpers live in
    /// `StowerStartupModelAnalytics.swift` (the same split-across-files posture as
    /// `StowerBoardViewModel`'s `Drafts`/`Load`/`Triage` extensions) so this file
    /// stays focused on the state machine itself.
    internal func commit(
        _ newState: StowerStartupState,
        generation: Int,
        emitsFunnelEvent: Bool = true
    ) {
        guard generation == self.generation else { return }
        state = newState
        onCommit?(newState)
        guard emitsFunnelEvent else { return }
        emitFunnelEvent(for: newState)
    }
}
