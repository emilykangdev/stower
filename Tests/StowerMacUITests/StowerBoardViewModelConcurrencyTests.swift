import Foundation
import Testing

@testable import StowerMacUI

/// The board view-model's concurrency guards (I13).
///
/// The load-staleness guard, the preset-independent refresh that reloads at the
/// current preset, and the cancel / generation discipline that stops a superseded
/// refresh from blocking or clobbering a newer one. Driven by
/// `StowerSpyBoardDataSource` with gated loads/refreshes so completion order is
/// deterministic.
@MainActor
@Suite internal struct StowerBoardViewModelConcurrencyTests {
    private final class FailureRecorder {
        var failures: [StowerStartupFailure] = []
    }

    private func makeRow(chatID: String) -> StowerBoardRow {
        StowerBoardRow(
            chatID: chatID,
            counterpart: "Alex",
            counterpartHandle: "+14155550100",
            monogram: "A",
            summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
            ageInDays: 2,
            deepLink: nil
        )
    }

    private var emptyModel: StowerBoardModel { StowerBoardModel(neglected: [], ghosted: []) }

    private func board(neglected: [String]) -> StowerBoardModel {
        StowerBoardModel(neglected: neglected.map { makeRow(chatID: $0) }, ghosted: [])
    }

    private func makeViewModel(_ spy: StowerSpyBoardDataSource) -> StowerBoardViewModel {
        StowerBoardViewModel(dataSource: spy, onFailure: { _ in }, sleep: { _ in })
    }

    private func settle(_ model: StowerBoardViewModel) async {
        for _ in 0..<2 {
            await model.refreshTaskHandle?.value
            await model.loadTaskHandle?.value
        }
    }

    @Test("a stale load's late result is discarded, not applied (I13)")
    internal func staleLoadDiscarded() async {
        let spy = StowerSpyBoardDataSource()
        spy.gateLoads = true
        let model = makeViewModel(spy)
        let modelA = board(neglected: ["stale"])
        let modelB = board(neglected: ["fresh"])

        model.load()
        while spy.pendingLoadGateCount < 1 { await Task.yield() }
        model.selectPreset(.twentyEightDays)
        while spy.pendingLoadGateCount < 2 { await Task.yield() }

        // Release the newer load (B) first; it applies.
        spy.releaseLoad(at: 1, with: modelB)
        await Task.yield()
        #expect(model.board?.rows(for: .neglected).map(\.id) == ["fresh"])

        // Release the older, superseded load (A) last; its result must be ignored.
        spy.releaseLoad(at: 0, with: modelA)
        await Task.yield()
        #expect(model.board?.rows(for: .neglected).map(\.id) == ["fresh"])
    }

    @Test("cancel supersedes an in-flight load so its late result is discarded (I13)")
    internal func cancelDiscardsInFlightLoad() async {
        let spy = StowerSpyBoardDataSource()
        spy.gateLoads = true
        let model = makeViewModel(spy)

        model.load()
        while spy.pendingLoadGateCount < 1 { await Task.yield() }

        // Dismiss while the load is in flight; releasing it afterwards must not
        // apply stale board state (cancel superseded the load generation).
        model.cancel()
        spy.releaseLoad(at: 0, with: board(neglected: ["stale"]))
        await Task.yield()
        #expect(model.board == nil)
    }

    @Test("a refresh completion reloads at the CURRENT preset, not the start preset (I13)")
    internal func refreshReloadsAtCurrentPreset() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel, board(neglected: ["n"])]
        spy.refreshOutcomes = [.completed(reloadNeeded: true, anyJudged: true, hadRecords: true)]
        let model = makeViewModel(spy)

        model.load()
        await model.loadTaskHandle?.value
        model.selectPreset(.ninetyDays)
        await model.loadTaskHandle?.value

        model.refresh()
        await settle(model)

        #expect(spy.recordedLoadConfigs.last?.unansweredForDays == 90)
        #expect(model.phase == .rows)
    }

    @Test("cancel resets the refresh guard so a reappear refresh is not blocked (I13)")
    internal func cancelUnblocksReappearRefresh() async {
        let spy = StowerSpyBoardDataSource()
        spy.gateRefresh = true
        spy.loadModels = [emptyModel]
        let model = makeViewModel(spy)

        model.refresh()
        while spy.pendingRefreshGateCount < 1 { await Task.yield() }
        #expect(model.isRefreshing)

        // Dismiss mid-refresh: the gated task can't unwind yet, but the guard must
        // reset so the reappear refresh is not blocked.
        model.cancel()
        #expect(model.isRefreshing == false)

        spy.gateRefresh = false
        spy.refreshOutcomes = [.completed(reloadNeeded: false, anyJudged: false, hadRecords: false)]
        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)
        #expect(spy.refreshCallCount == 2)
        #expect(model.phase == .caughtUp)
        let loadsBeforeRelease = spy.loadCallCount

        // The superseded, parked task's late exit must not apply its outcome over the
        // newer board: even a state-changing .completed is dropped by the generation
        // guard (no reload, no phase change, no clobbered isRefreshing).
        spy.releaseRefresh(
            at: 0,
            with: .completed(reloadNeeded: true, anyJudged: true, hadRecords: true)
        )
        await Task.yield()
        #expect(model.phase == .caughtUp)
        #expect(model.isRefreshing == false)
        #expect(spy.loadCallCount == loadsBeforeRelease)
    }
}
