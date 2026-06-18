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
    private var inFlight: Task<Void, Never>?
    private var generation = 0

    /// Minimum time the checking state stays up, so a fast result doesn't flash.
    private static let minimumCheckingDisplay: Duration = .milliseconds(400)

    /// Creates the startup model.
    ///
    /// - Parameters:
    ///   - provider: The startup boundary (the real adapter in production, a fake
    ///     in tests).
    ///   - licenseGate: The license seam (the real Lemon Squeezy gate in
    ///     production, a fake in tests). No default — a "has license" default
    ///     would ship a paywall bypass.
    ///   - config: The debt-board knobs passed to every load.
    ///   - clock: Supplies `now`; injectable so tests are deterministic.
    ///   - sleep: The minimum-display delay; injectable so tests need no real
    ///     wall-clock wait. Throwing, because `Task.sleep(for:)` throws.
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
        onCommit: (@MainActor @Sendable (StowerStartupState) -> Void)? = nil
    ) {
        self.provider = provider
        self.licenseGate = licenseGate
        self.config = config
        self.clock = clock
        self.sleep = sleep
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

    /// Activates the license key entered on `StowerLicenseEntryView`.
    ///
    /// Re-entrant, mirroring `beginRun`'s `[weak self]` capture and generation
    /// token. Trims once at this boundary so the stored key equals the activated
    /// key; an all-whitespace field can't submit (the entry view also disables on
    /// an empty trim).
    internal func submitLicense(_ rawKey: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        inFlight?.cancel()
        generation += 1
        let runGeneration = generation
        inFlight = Task { [weak self] in
            await self?.runActivation(key: key, generation: runGeneration)
        }
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
        state = route(failure, wasAwaitingFDA: state.isAwaitingFullDiskAccess)
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
            // A stored license ⇒ licensed: a pure local read, no network and no
            // spinner. Otherwise show the entry screen; the launch path never
            // calls `/activate`.
            if licenseGate.hasStoredLicense() == false {
                try await minimumDisplayDone
                commit(.needsLicense(nil), generation: generation)
                return
            }
            let target = try await continueAfterLicense(
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

    /// The post-license tail of startup: probe the board and route.
    ///
    /// Factored out of `runStartup` so the activate path (`runActivation`) reuses
    /// it verbatim; returns the target state so the caller honors the minimum
    /// display before committing it.
    private func continueAfterLicense(
        generation: Int,
        wasAwaitingFDA: Bool
    ) async throws -> StowerStartupState {
        commit(.checkingMessages, generation: generation)
        return try await loadAndRoute(wasAwaitingFDA: wasAwaitingFDA)
    }

    /// The activate flow body, under the same generation token, minimum-display
    /// delay, and do/catch wrapper as `runStartup` — no second concurrency scheme.
    ///
    /// `activate` is pure; the license is persisted only after the generation
    /// guard, so a superseded activation (a newer submit bumped the generation
    /// before this one returned) neither persists nor commits.
    private func runActivation(key: String, generation: Int) async {
        commit(.checkingLicense, generation: generation)
        let sleepClosure = sleep
        let minimumDisplay = Self.minimumCheckingDisplay
        do {
            async let minimumDisplayDone: Void = sleepClosure(minimumDisplay)
            let outcome = await licenseGate.activate(key: key)
            guard generation == self.generation else { return }
            switch outcome {
            case .activated(let instanceID):
                licenseGate.persistLicense(key: key, instanceID: instanceID)
                let target = try await continueAfterLicense(
                    generation: generation,
                    wasAwaitingFDA: false
                )
                try await minimumDisplayDone
                commit(target, generation: generation)
            case .invalid:
                try await minimumDisplayDone
                commit(.needsLicense(.invalid), generation: generation)
            case .couldNotReach:
                try await minimumDisplayDone
                commit(.needsLicense(.couldNotReach), generation: generation)
            }
        } catch is CancellationError {
            // A superseded / cancelled activation never routes to a failure screen.
        } catch {
            commit(.failed(.unexpected), generation: generation)
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

    /// Applies a new state only if its run is still the current generation, so a
    /// stale completion can't overwrite a newer run's result.
    private func commit(_ newState: StowerStartupState, generation: Int) {
        guard generation == self.generation else { return }
        state = newState
        onCommit?(newState)
    }
}
