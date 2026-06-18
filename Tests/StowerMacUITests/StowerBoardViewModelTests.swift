import Foundation
import Testing

@testable import StowerMacUI

/// The board/thread view-model behaviors: failure re-routing (I4),
/// reload-iff-changed (I6), preparing→terminal resolution (I6b),
/// toggle-no-requery (I7), filter-requery (I8), the usable/empty/broken split
/// (I9), and the load-staleness guard (I13).
///
/// Driven by `StowerSpyBoardDataSource` — no engine, no real model.
@MainActor
@Suite internal struct StowerBoardViewModelTests {
    /// Collects failures the view-model routes back to the startup model.
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

    private func board(neglected: [String] = [], ghosted: [String] = []) -> StowerBoardModel {
        StowerBoardModel(
            neglected: neglected.map { makeRow(chatID: $0) },
            ghosted: ghosted.map { makeRow(chatID: $0) }
        )
    }

    private func makeViewModel(
        _ spy: StowerSpyBoardDataSource,
        recorder: FailureRecorder
    ) -> StowerBoardViewModel {
        StowerBoardViewModel(
            dataSource: spy,
            onFailure: { recorder.failures.append($0) },
            sleep: { _ in }
        )
    }

    /// Awaits the in-flight refresh and any reload it spawns, twice, to quiesce.
    private func settle(_ model: StowerBoardViewModel) async {
        for _ in 0..<2 {
            await model.refreshTaskHandle?.value
            await model.loadTaskHandle?.value
        }
    }

    // MARK: I4 — a board failure re-routes (never an empty board)

    @Test("a load failure routes via onFailure and renders no board (I4)")
    internal func loadFailureRoutes() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadError = .fullDiskAccessMissing(path: "~/Library/Messages/chat.db")
        let recorder = FailureRecorder()
        let model = makeViewModel(spy, recorder: recorder)

        model.load()
        await model.loadTaskHandle?.value

        #expect(recorder.failures == [.fullDiskAccessMissing(path: "~/Library/Messages/chat.db")])
        #expect(model.board == nil)
        #expect(model.phase == .preparing)
    }

    // MARK: I7 — the direction toggle never re-queries

    @Test("toggling direction reads the one loaded model, issuing no extra load (I7)")
    internal func toggleDoesNotRequery() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [board(neglected: ["n"], ghosted: ["g"])]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        #expect(spy.loadCallCount == 1)

        model.direction = .ghosted
        #expect(spy.loadCallCount == 1)
        #expect(model.board?.rows(for: .neglected).map(\.id) == ["n"])
        #expect(model.board?.rows(for: .ghosted).map(\.id) == ["g"])
    }

    // MARK: I8 — a day-preset change re-runs the load at the new threshold

    @Test("changing the preset issues one load with the new unansweredForDays (I8)")
    internal func presetChangeRequeries() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.selectPreset(.twentyEightDays)
        await model.loadTaskHandle?.value

        #expect(spy.loadCallCount == 2)
        #expect(spy.recordedLoadConfigs.first?.unansweredForDays == StowerDayPreset.default.days)
        #expect(spy.recordedLoadConfigs.last?.unansweredForDays == 28)
    }

    @Test("re-selecting the same preset does not re-load")
    internal func samePresetDoesNotRequery() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.selectPreset(.default)

        #expect(spy.loadCallCount == 1)
    }

    // MARK: I6 / I6b / I9 — refresh outcomes resolve the preparing state

    @Test("a completed pass with changes reloads and shows rows (I6/I6b/I9)")
    internal func completedWithChangesShowsRows() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel, board(neglected: ["n"])]
        spy.refreshOutcomes = [.completed(reloadNeeded: true, anyJudged: true, hadRecords: true)]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        #expect(model.phase == .preparing)

        model.refresh()
        await settle(model)

        #expect(spy.loadCallCount == 2)
        #expect(model.phase == .rows)
        #expect(model.board?.rows(for: .neglected).map(\.id) == ["n"])
    }

    @Test("a completed pass that judged but gated to empty is all-caught-up, no reload (I6/I9)")
    internal func completedJudgedButEmptyIsCaughtUp() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        spy.refreshOutcomes = [.completed(reloadNeeded: false, anyJudged: true, hadRecords: true)]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)

        #expect(spy.loadCallCount == 1)
        #expect(model.phase == .caughtUp)
    }

    @Test("an empty snapshot is all-caught-up, not an error (I9)")
    internal func emptySnapshotIsCaughtUp() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        spy.refreshOutcomes = [.completed(reloadNeeded: false, anyJudged: false, hadRecords: false)]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)

        #expect(model.phase == .caughtUp)
    }

    @Test("a total failure (records but judged none) is a retryable error (I9)")
    internal func totalFailureIsError() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        spy.refreshOutcomes = [.completed(reloadNeeded: false, anyJudged: false, hadRecords: true)]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)

        #expect(model.phase == .error)
    }

    @Test("an incomplete pass keeps preparing and re-issues the refresh (I6b)")
    internal func incompleteReissuesWithoutDeadlock() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        spy.refreshOutcomes = [
            .incomplete(reloadNeeded: false),
            .completed(reloadNeeded: false, anyJudged: false, hadRecords: false)
        ]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)

        #expect(spy.refreshCallCount == 2)
        #expect(model.phase == .caughtUp)
        #expect(model.isRefreshing == false)
    }

    @Test("a coalesced pass after cold start is resolved is a no-op (I6)")
    internal func coalescedAfterResolvedIsNoOp() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        spy.refreshOutcomes = [
            .completed(reloadNeeded: false, anyJudged: false, hadRecords: false),
            .coalesced
        ]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)
        #expect(model.phase == .caughtUp)

        // A later coalesced pass must not clear or reload the resolved board.
        model.refresh()
        await settle(model)
        #expect(spy.refreshCallCount == 2)
        #expect(spy.loadCallCount == 1)
        #expect(model.phase == .caughtUp)
    }

    @Test("a coalesced pass during cold start backs off and re-issues, never stranding")
    internal func coalescedDuringColdStartReissues() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        spy.refreshOutcomes = [
            .coalesced,
            .completed(reloadNeeded: false, anyJudged: false, hadRecords: false)
        ]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)

        #expect(spy.refreshCallCount == 2)
        #expect(model.phase == .caughtUp)
        #expect(model.isRefreshing == false)
    }

    // MARK: I13 — the staleness guard is on load only

    @Test("a stale load's late result is discarded, not applied (I13)")
    internal func staleLoadDiscarded() async {
        let spy = StowerSpyBoardDataSource()
        spy.gateLoads = true
        let model = makeViewModel(spy, recorder: FailureRecorder())
        let modelA = StowerBoardModel(neglected: [makeRow(chatID: "stale")], ghosted: [])
        let modelB = StowerBoardModel(neglected: [makeRow(chatID: "fresh")], ghosted: [])

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

    @Test("a refresh completion reloads at the CURRENT preset, not the start preset (I13)")
    internal func refreshReloadsAtCurrentPreset() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel, board(neglected: ["n"])]
        spy.refreshOutcomes = [.completed(reloadNeeded: true, anyJudged: true, hadRecords: true)]
        let model = makeViewModel(spy, recorder: FailureRecorder())

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
        let model = makeViewModel(spy, recorder: FailureRecorder())

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

        // The superseded, parked task's late exit must not clobber the resolved board.
        spy.releaseRefresh(at: 0, with: .coalesced)
        await Task.yield()
        #expect(model.phase == .caughtUp)
        #expect(model.isRefreshing == false)
    }
}
