import Foundation

@testable import StowerMacUI

/// A Tests-only `StowerBoardDataSource` double for the board/thread view-model
/// tests (no engine, no real model).
///
/// Scriptable: queues of board models / refresh outcomes / thread lines (the last
/// queued value is reused once a queue is spent), plus optional thrown failures. It
/// records call counts and the configs it was handed so a test can assert
/// re-query-on-filter (I8) and no-requery-on-toggle (I7). Loads can be **gated** on
/// continuations so the staleness test (I13) controls completion order. It is
/// `@MainActor`, matching the view-models, so the tests are single-threaded and
/// deterministic.
@MainActor
internal final class StowerSpyBoardDataSource: StowerBoardDataSource {
    /// Board models returned by successive `loadBoard` calls (FIFO; last reused).
    internal var loadModels: [StowerBoardModel] = []

    /// When set, every `loadBoard` throws this instead of returning a model.
    internal var loadError: StowerStartupFailure?

    /// Outcomes returned by successive `refreshJudgments` calls (FIFO; last reused).
    internal var refreshOutcomes: [StowerBoardRefreshOutcome] = []

    /// When set, every `refreshJudgments` throws this.
    internal var refreshError: StowerStartupFailure?

    /// Lines returned by `thread`.
    internal var threadLines: [StowerThreadLine] = []

    /// When set, every `thread` throws this.
    internal var threadError: StowerStartupFailure?

    /// When `true`, `loadBoard` suspends on a gate the test releases explicitly.
    internal var gateLoads = false

    /// When `true`, `refreshJudgments` suspends on a gate the test releases.
    internal var gateRefresh = false

    private(set) internal var loadCallCount = 0
    private(set) internal var refreshCallCount = 0
    private(set) internal var threadCallCount = 0
    private(set) internal var recordedLoadConfigs: [StowerStartupDebtConfig] = []
    private(set) internal var recordedRefreshConfigs: [StowerStartupDebtConfig] = []

    private var loadGates: [CheckedContinuation<StowerBoardModel, Error>] = []
    private var refreshGates: [CheckedContinuation<StowerBoardRefreshOutcome, Error>] = []

    /// How many gated loads are suspended awaiting release.
    internal var pendingLoadGateCount: Int { loadGates.count }

    /// How many gated refreshes are suspended awaiting release.
    internal var pendingRefreshGateCount: Int { refreshGates.count }

    internal func loadBoard(
        config: StowerStartupDebtConfig,
        now: Date
    ) async throws -> StowerBoardModel {
        loadCallCount += 1
        recordedLoadConfigs.append(config)
        if let loadError {
            throw loadError
        }
        if gateLoads {
            return try await withCheckedThrowingContinuation { loadGates.append($0) }
        }
        return dequeue(&loadModels) ?? StowerBoardModel(neglected: [], ghosted: [])
    }

    internal func thread(chatID: String, limit: Int) async throws -> [StowerThreadLine] {
        threadCallCount += 1
        if let threadError {
            throw threadError
        }
        return threadLines
    }

    internal func refreshJudgments(
        config: StowerStartupDebtConfig,
        now: Date
    ) async throws -> StowerBoardRefreshOutcome {
        refreshCallCount += 1
        recordedRefreshConfigs.append(config)
        if let refreshError {
            throw refreshError
        }
        if gateRefresh {
            return try await withCheckedThrowingContinuation { refreshGates.append($0) }
        }
        return dequeue(&refreshOutcomes) ?? .coalesced
    }

    /// Resumes a gated load with `model`.
    internal func releaseLoad(at index: Int, with model: StowerBoardModel) {
        loadGates.remove(at: index).resume(returning: model)
    }

    /// Resumes a gated refresh with `outcome`.
    internal func releaseRefresh(at index: Int, with outcome: StowerBoardRefreshOutcome) {
        refreshGates.remove(at: index).resume(returning: outcome)
    }

    private func dequeue<Element>(_ queue: inout [Element]) -> Element? {
        guard !queue.isEmpty else { return nil }
        if queue.count == 1 {
            return queue[0]
        }
        return queue.removeFirst()
    }
}
