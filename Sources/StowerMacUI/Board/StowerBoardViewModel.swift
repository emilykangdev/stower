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

    private let dataSource: any StowerBoardDataSource
    private let opener: StowerMessagesLinkOpener
    private let onFailure: @MainActor (StowerStartupFailure) -> Void
    private let clock: @Sendable () -> Date

    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var hasResolvedColdStart = false

    /// Creates the board view-model.
    ///
    /// - Parameters:
    ///   - dataSource: The app-owned board boundary (live adapter or a spy).
    ///   - opener: The Messages deep-link opener handed to thread view-models.
    ///   - onFailure: Routes a board failure back to the startup model.
    ///   - clock: Supplies `now`; injectable so tests are deterministic.
    internal init(
        dataSource: any StowerBoardDataSource,
        opener: StowerMessagesLinkOpener = StowerMessagesLinkOpener(),
        onFailure: @escaping @MainActor (StowerStartupFailure) -> Void,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataSource = dataSource
        self.opener = opener
        self.onFailure = onFailure
        self.clock = clock
    }

    /// Runs the launch sequence on appear: load the cached board, then refresh.
    ///
    /// Called once per board appearance (SwiftUI's `.task`), so re-entering the
    /// board after an FDA-recovery round-trip reloads. A redundant call is safe:
    /// `load()` supersedes via its generation token and `refresh()` is guarded by
    /// `isRefreshing`.
    internal func onAppear() {
        load()
        refresh()
    }

    /// Selects a new day preset, re-loading at the new threshold (I8).
    internal func selectPreset(_ preset: StowerDayPreset) {
        guard preset != selectedPreset else { return }
        selectedPreset = preset
        load()
    }

    /// Re-attempts the model pass after a board-level error.
    internal func retry() {
        phase = .preparing
        refresh()
    }

    /// Cancels in-flight work when the board view disappears.
    internal func cancel() {
        loadTask?.cancel()
        refreshTask?.cancel()
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

    /// The in-flight load/refresh tasks, exposed so tests can await them.
    internal var loadTaskHandle: Task<Void, Never>? { loadTask }
    internal var refreshTaskHandle: Task<Void, Never>? { refreshTask }

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
        refreshTask = Task { [weak self] in
            await self?.runRefreshLoop()
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
    private func runRefreshLoop() async {
        defer { isRefreshing = false }
        do {
            while true {
                let outcome = try await dataSource.refreshJudgments(config: config, now: clock())
                switch outcome {
                case .coalesced:
                    return
                case .completed(let reloadNeeded, let anyJudged, let hadRecords):
                    applyCompleted(
                        reloadNeeded: reloadNeeded,
                        anyJudged: anyJudged,
                        hadRecords: hadRecords
                    )
                    return
                case .incomplete:
                    if Task.isCancelled { return }
                }
            }
        } catch is CancellationError {
            // Superseded / dismissed — never a failure.
        } catch let failure as StowerStartupFailure {
            onFailure(failure)
        } catch {
            onFailure(.unexpected)
        }
    }

    private func applyCompleted(reloadNeeded: Bool, anyJudged: Bool, hadRecords: Bool) {
        hasResolvedColdStart = true
        if anyJudged {
            if reloadNeeded {
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
