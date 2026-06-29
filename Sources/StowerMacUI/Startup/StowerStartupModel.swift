import Foundation
import Observation

/// Drives the FDA-first startup flow and owns the single `StowerStartupState` the
/// root view renders.
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
    private let licenseGate: any StowerLicenseGating
    private let config: StowerStartupDebtConfig
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onCommit: (@MainActor @Sendable (StowerStartupState) -> Void)?
    private let reporter: any StowerAnalyticsReporting
    private var inFlight: Task<Void, Never>?
    private var generation = 0

    /// `true` while a run is in an FDA-awaiting state; cleared after `fda_permission_resolved` fires.
    ///
    /// Drives the `wasAwaitingFDA` latch so `checkAgain()` re-runs don't double-fire
    /// `fda_permission_requested`.
    private var wasAwaitingFDA = false

    /// Guards `board_reached` to one emission per launch (per-launch semantics).
    private var boardReachedThisLaunch = false

    /// Minimum time the checking state stays up, so a fast result doesn't flash.
    private static let minimumCheckingDisplay: Duration = .milliseconds(400)

    /// Creates the startup model.
    ///
    /// - Parameters:
    ///   - provider: The startup boundary (the real adapter in production, a fake
    ///     in tests).
    ///   - licenseGate: The license seam (the real Edge-Function-backed
    ///     `StowerLicenseGate` in production, a fake in tests). No default — a "has
    ///     license" default would ship a paywall bypass.
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

    /// Reruns the same startup flow (the FDA / failure screens' Check Again).
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

    /// The trial badge data decoded from the signed machine file, or `nil` when
    /// there is no active trial or the machine file can't be read.
    ///
    /// Read-through to `licenseGate.trialBadge()`. Callers gate on this before
    /// showing the badge; the dismissal flag is NOT wired here (I3).
    internal func trialBadge() -> StowerTrialBadge? {
        licenseGate.trialBadge()
    }

    /// Routes a board-load failure back into the startup screen flow.
    ///
    /// The board runs as a child `StowerBoardViewModel` rooted at
    /// `.connectedPreparingBoard`; when its load surfaces a `StowerStartupFailure`
    /// (e.g. a mid-session FDA/source error), it re-enters onboarding here. Cancels
    /// any in-flight startup run and bumps the generation so a late startup
    /// completion can't overwrite this, then routes the failure exactly as startup
    /// would — FDA escalation included, via the shared `route(_:wasAwaitingFDA:)`.
    internal func handleBoardFailure(_ failure: StowerStartupFailure) {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        let next = route(failure, wasAwaitingFDA: state.isAwaitingFullDiskAccess)
        commit(next, generation: generation)
    }

    /// Re-checks the license without disrupting the board — called when the app
    /// returns to the foreground (e.g. back from the Lemon Squeezy checkout), so a
    /// just-completed purchase reflects instantly: the `/check-in` refreshes the
    /// cached lease (clearing the trial badge once the license is paid) with no full
    /// startup re-run and no "Loading Stower…" flash.
    ///
    /// Acts only while on the board. A definitive `.trialExpired` / `.wrongVersion`
    /// routes to the paywall; `.valid` and the transient states (`.couldNotReach` /
    /// `.needsTrialOnline`) leave the board in place — a network blip must never
    /// paywall a user who was already valid. The generation guard drops the result
    /// if a fresh startup run (Check Again) began during the await.
    internal func refreshLicenseIfOnBoard() async {
        guard state == .connectedPreparingBoard else { return }
        let runGeneration = generation
        let status = await licenseGate.currentStatus(now: clock())
        guard generation == runGeneration, state == .connectedPreparingBoard else { return }
        switch status {
        case .valid, .couldNotReach, .needsTrialOnline:
            break
        case .trialExpired(let id):
            commit(.needsLicense(.trialExpired(licenseID: id)), generation: runGeneration)
        case .wrongVersion(let id):
            commit(.needsLicense(.upgradeRequired(licenseID: id)), generation: runGeneration)
        }
    }

    /// Cancels any in-flight run, bumps the generation, and starts a fresh run.
    private func beginRun() {
        inFlight?.cancel()
        generation += 1
        let runGeneration = generation
        let wasAwaitingFDA = state.isAwaitingFullDiskAccess
        inFlight = Task { [weak self] in
            await self?.runStartup(generation: runGeneration, wasAwaitingFDA: wasAwaitingFDA)
        }
    }

    /// The flow body: preflight availability, load, route — under the generation
    /// token and the minimum-display delay.
    private func runStartup(generation: Int, wasAwaitingFDA: Bool) async {
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
            // The license check inserts after availability, before the board probe.
            // The spinner stays neutral ("Loading Stower…") — trial-vs-paid is unknown
            // until the server replies, and a cleared lease can still be paid.
            commit(.checkingLicense, generation: generation)
            let status = await licenseGate.currentStatus(now: clock())
            guard generation == self.generation else { return }
            let target = try await route(
                licenseStatus: status,
                generation: generation,
                wasAwaitingFDA: wasAwaitingFDA
            )
            try await minimumDisplayDone
            commit(target, generation: generation)
        } catch is CancellationError {
            // A superseded / cancelled run never routes to a failure screen.
        } catch {
            commit(.failed(.unexpected), generation: generation)
        }
    }

    /// Maps a license status to the next state: `.valid` probes the board (the
    /// post-license tail), every other status routes to its entry-screen context.
    private func route(
        licenseStatus: StowerLicenseStatus,
        generation: Int,
        wasAwaitingFDA: Bool
    ) async throws -> StowerStartupState {
        switch licenseStatus {
        case .valid:
            commit(.checkingMessages, generation: generation)
            return try await loadAndRoute(wasAwaitingFDA: wasAwaitingFDA)
        case .trialExpired(let id):
            return .needsLicense(.trialExpired(licenseID: id))
        case .wrongVersion(let id):
            return .needsLicense(.upgradeRequired(licenseID: id))
        case .couldNotReach:
            return .needsLicense(.couldNotReach)
        case .needsTrialOnline:
            return .needsLicense(.connectOnce)
        }
    }

    /// Loads the board and maps a `StowerStartupFailure` to a state; lets a
    /// `CancellationError` (and any non-app error) propagate to `runStartup`.
    private func loadAndRoute(wasAwaitingFDA: Bool) async throws -> StowerStartupState {
        do {
            try await provider.loadDebtBoard(config: config, now: clock())
            return .connectedPreparingBoard
        } catch let failure as StowerStartupFailure {
            return route(failure, wasAwaitingFDA: wasAwaitingFDA)
        }
    }

    /// Maps a typed failure to the right screen (the three-outcomes routing).
    private func route(
        _ failure: StowerStartupFailure,
        wasAwaitingFDA: Bool
    ) -> StowerStartupState {
        switch failure {
        case .fullDiskAccessMissing(let path):
            return wasAwaitingFDA
                ? .needsFullDiskAccessStillMissing(path: path)
                : .needsFullDiskAccess(path: path)
        case .modelUnavailable(let reason):
            return .modelUnavailable(reason)
        case .invalidConfig, .sourceMissing, .unreadable, .invalidData, .unexpected:
            return .failed(failure)
        }
    }

    /// Applies a new state only if its run is still the current generation.
    ///
    /// A stale completion can't overwrite a newer run's result. Also emits funnel
    /// analytics events via the reporter on each committed state (Eng F1).
    private func commit(_ newState: StowerStartupState, generation: Int) {
        guard generation == self.generation else { return }
        state = newState
        onCommit?(newState)
        emitFunnelEvent(for: newState)
    }

    /// Emits the appropriate funnel analytics event for a committed state.
    ///
    /// Uses the `wasAwaitingFDA` latch so `fda_permission_resolved` fires
    /// exactly once per run that entered an FDA state, and the
    /// `boardReachedThisLaunch` flag so `board_reached` fires once per launch.
    /// Driven off `commit` (not adjacent-state matching or `onAppear`) per
    /// Eng F1/F2.
    ///
    /// `fda_permission_resolved(granted:true)` fires only at
    /// `.connectedPreparingBoard` — NOT at `.checkingMessages`. The board is
    /// entered optimistically: `.checkingMessages` commits before
    /// `loadDebtBoard` runs, and that load can still throw
    /// `fullDiskAccessMissing` and route to `.needsFullDiskAccessStillMissing`.
    /// Resolving at `.checkingMessages` would record a false "granted" for every
    /// user who returned from the FDA screen without granting. Reaching the board
    /// is the only proof access actually works. FDA denial is measured as
    /// `fda_permission_requested` without a subsequent `fda_permission_resolved`.
    private func emitFunnelEvent(for state: StowerStartupState) {
        switch state {
        case .modelUnavailable(let reason):
            reporter.report(.hardwareChecked(supported: false, reason: "\(reason)"))

        case .checkingLicense:
            // Model was available (hardware check passed).
            reporter.report(.hardwareChecked(supported: true, reason: nil))

        case .needsLicense(let context):
            reporter.report(.licenseGateReached(context: context))

        case .needsFullDiskAccess:
            reporter.report(.fdaPermissionRequested)
            wasAwaitingFDA = true

        case .connectedPreparingBoard:
            resolveFDAIfNeeded()
            emitBoardReachedIfNeeded()

        case .checkingModel, .checkingMessages, .needsFullDiskAccessStillMissing, .failed:
            break
        }
    }

    /// Emits `fda_permission_resolved(granted:true)` when the FDA latch is set.
    ///
    /// Fires once per run that entered a `needsFullDiskAccess` state, only after
    /// the board is reached (access proven); clears the latch afterward so it
    /// cannot double-fire.
    private func resolveFDAIfNeeded() {
        guard wasAwaitingFDA else { return }
        reporter.report(.fdaPermissionResolved(granted: true))
        wasAwaitingFDA = false
    }

    /// Emits `board_reached` at most once per launch via the `boardReachedThisLaunch` latch.
    private func emitBoardReachedIfNeeded() {
        guard !boardReachedThisLaunch else { return }
        reporter.report(.boardReached)
        boardReachedThisLaunch = true
    }
}
