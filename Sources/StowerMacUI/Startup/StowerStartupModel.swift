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
    private let config: StowerStartupDebtConfig
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var inFlight: Task<Void, Never>?
    private var generation = 0

    /// Minimum time the checking state stays up, so a fast result doesn't flash.
    private static let minimumCheckingDisplay: Duration = .milliseconds(400)

    /// Creates the startup model.
    ///
    /// - Parameters:
    ///   - provider: The startup boundary (the real adapter in production, a fake
    ///     in tests).
    ///   - config: The debt-board knobs passed to every load.
    ///   - clock: Supplies `now`; injectable so tests are deterministic.
    ///   - sleep: The minimum-display delay; injectable so tests need no real
    ///     wall-clock wait. Throwing, because `Task.sleep(for:)` throws.
    internal init(
        provider: any StowerStartupProviding,
        config: StowerStartupDebtConfig = .appDefault,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.provider = provider
        self.config = config
        self.clock = clock
        self.sleep = sleep
    }

    /// Runs the startup flow once (initial launch).
    internal func start() {
        beginRun()
    }

    /// Reruns the same startup flow (the FDA / failure screens' Check Again).
    internal func checkAgain() {
        beginRun()
    }

    /// The current run, exposed so a test can await the fire-and-forget flow.
    ///
    /// Not used by the views.
    internal var activeRun: Task<Void, Never>? { inFlight }

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
            commit(.checkingMessages, generation: generation)
            let target = try await loadAndRoute(wasAwaitingFDA: wasAwaitingFDA)
            try await minimumDisplayDone
            commit(target, generation: generation)
        } catch is CancellationError {
            // A superseded / cancelled run never routes to a failure screen.
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
    }
}
