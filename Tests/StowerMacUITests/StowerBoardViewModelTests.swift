import Foundation
import StowerMessages
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
            draftKey: StowerDraftKey.derive(forHandle: "+14155550100"),
            lastMessageGUID: "guid-\(chatID)",
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

    // MARK: I7 — switching the lens tab never re-queries

    @Test("switching the lens tab reads the one loaded model, issuing no extra load (I7)")
    internal func toggleDoesNotRequery() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [board(neglected: ["n"], ghosted: ["g"])]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        #expect(spy.loadCallCount == 1)

        // selectedTab subsumes direction; selecting a lens tab must not reload (I7).
        model.selectedTab = .maybeFollowUp
        #expect(spy.loadCallCount == 1)
        #expect(model.direction == .ghosted)
        #expect(model.board?.rows(for: .neglected).map(\.id) == ["n"])
        #expect(model.board?.rows(for: .ghosted).map(\.id) == ["g"])
    }

    // MARK: I8 — a day-preset change re-runs the load at the new threshold

    @Test("changing the preset issues one load with the new unansweredForDays (I8)")
    internal func presetChangeRequeries() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        // The default is .all (0 days), so the launch load hides nothing by age.
        #expect(model.selectedPreset == .all)
        model.load()
        await model.loadTaskHandle?.value
        model.selectPreset(.twentyEightDays)
        await model.loadTaskHandle?.value

        #expect(spy.loadCallCount == 2)
        #expect(StowerDayPreset.default.days == 0)
        #expect(spy.recordedLoadConfigs.first?.unansweredForDays == 0)
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

    @Test("a cold-start completed pass reloads a warm cache even when nothing changed (I9)")
    internal func coldStartReloadsWarmCache() async {
        // Cold load is empty; we coalesced against another pass that warmed the
        // cache, so our completed pass reports anyJudged but reloadNeeded=false. We
        // must still reload — otherwise a false "all caught up" over real rows.
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel, board(neglected: ["n"])]
        spy.refreshOutcomes = [.completed(reloadNeeded: false, anyJudged: true, hadRecords: true)]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)

        #expect(spy.loadCallCount == 2)
        #expect(model.phase == .rows)
        #expect(model.board?.rows(for: .neglected).map(\.id) == ["n"])
    }

    @Test("a cold-start completed pass that reloads to a still-empty board is all-caught-up (I9)")
    internal func coldStartReloadEmptyIsCaughtUp() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        spy.refreshOutcomes = [.completed(reloadNeeded: false, anyJudged: true, hadRecords: true)]
        let model = makeViewModel(spy, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        model.refresh()
        await settle(model)

        #expect(spy.loadCallCount == 2)
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
}
