import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// A fixed clock so recorded `occurredAt` stamps are deterministic.
private let triageFixedNow = Date(timeIntervalSince1970: 5_000_000)

/// The board view-model's triage behaviors: undo granularity (I6), interaction
/// recording (I14), the no-bar-on-failed-write rule, batch Select mode (B2), and the
/// mute / unmute + muted-count path that drives the zero-state line (I12).
///
/// Driven by `StowerSpyBoardDataSource` (no engine) plus an injected in-memory triage
/// store, spy recorder, and app-owned `UndoManager`, so every assertion reads real
/// post-action state, not a mock's call log.
@MainActor
@Suite internal struct StowerBoardViewModelTriageTests {
    private func makeRow(chatID: String, handle: String) -> StowerBoardRow {
        StowerBoardRow(
            chatID: chatID,
            counterpart: "Person \(chatID)",
            counterpartHandle: handle,
            draftKey: StowerDraftKey.derive(forHandle: handle),
            lastMessageGUID: "guid-\(chatID)",
            lastMessageTimestamp: Date(timeIntervalSince1970: 1_000_000),
            monogram: "P",
            summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
            ageInDays: 2,
            deepLink: nil
        )
    }

    /// A row whose handle is unique to `chatID` (distinct dismiss/mute keys per row).
    ///
    /// Derived deterministically from the chatID's scalars (fixed-width blocks) — NOT
    /// Swift's per-process-seeded `hashValue`, which is non-reproducible and whose
    /// modulo could collide two chatIDs onto one `draftKey` and flake the count asserts.
    private func uniqueRow(_ chatID: String) -> StowerBoardRow {
        let digits = chatID.unicodeScalars
            .map { String(format: "%03d", $0.value % 1000) }
            .joined()
        let suffix = String((digits + String(repeating: "0", count: 10)).prefix(10))
        return makeRow(chatID: chatID, handle: "+1\(suffix)")
    }

    private func makeViewModel(
        dataSource: StowerSpyBoardDataSource = StowerSpyBoardDataSource(),
        triage: any StowerTriageStoring,
        recorder: any StowerInteractionRecording = StowerNoOpInteractionRecorder(),
        undoManager: UndoManager = UndoManager()
    ) -> StowerBoardViewModel {
        StowerBoardViewModel(
            dataSource: dataSource,
            interactions: recorder,
            triage: triage,
            undoManager: undoManager,
            onFailure: { _ in },
            clock: { triageFixedNow },
            sleep: { _ in }
        )
    }

    private func settle(_ model: StowerBoardViewModel) async {
        await model.triageTaskHandle?.value
        await model.loadTaskHandle?.value
    }

    // MARK: I6 — undo granularity == the user's action

    @Test("a single dismiss writes one row; one undo restores exactly it (I6a)")
    internal func singleDismissUndo() async {
        let triage = StowerInMemoryTriageStore()
        let model = makeViewModel(triage: triage)
        let row = makeRow(chatID: "a", handle: "+14155550100")

        model.dismiss([row])
        await settle(model)
        #expect(await triage.dismissedMessages().keys.sorted() == [row.draftKey])
        #expect(model.undoBar?.count == 1)

        model.undoLastDismiss()
        await settle(model)
        #expect(await triage.dismissedMessages().isEmpty)
        #expect(model.undoBar == nil)
    }

    @Test("a batch dismiss is one undo step restoring the whole set (I6b)")
    internal func batchDismissUndo() async {
        let triage = StowerInMemoryTriageStore()
        let model = makeViewModel(triage: triage)
        let rows = Set([uniqueRow("a"), uniqueRow("b"), uniqueRow("c")])

        model.dismiss(rows)
        await settle(model)
        #expect(await triage.dismissedMessages().count == 3)
        #expect(model.undoBar?.count == 3)

        // ONE undo restores all three (one registerUndo per action — I6).
        model.undoLastDismiss()
        await settle(model)
        #expect(await triage.dismissedMessages().isEmpty)
    }

    @Test("three separate single dismisses are three undo steps (I6c)")
    internal func threeSinglesAreThreeUndoSteps() async {
        let triage = StowerInMemoryTriageStore()
        let model = makeViewModel(triage: triage)
        let rowA = uniqueRow("a")
        let rowB = uniqueRow("b")
        let rowC = uniqueRow("c")

        for row in [rowA, rowB, rowC] {
            model.dismiss([row])
            await settle(model)
        }
        #expect(await triage.dismissedMessages().count == 3)

        // Each ⌘Z reverses exactly one — they never coalesce (groupsByEvent off).
        model.undoLastDismiss()
        await settle(model)
        #expect(await triage.dismissedMessages().count == 2)

        model.undoLastDismiss()
        await settle(model)
        #expect(await triage.dismissedMessages().count == 1)

        model.undoLastDismiss()
        await settle(model)
        #expect(await triage.dismissedMessages().isEmpty)
    }

    @Test("two rapid dismisses (no await between) serialize and undo in reverse order")
    internal func rapidDismissesSerialize() async {
        let triage = StowerInMemoryTriageStore()
        let model = makeViewModel(triage: triage)
        let rowA = uniqueRow("a")
        let rowB = uniqueRow("b")

        // Fire both before awaiting — the chain must apply A then B, not interleave.
        model.dismiss([rowA])
        model.dismiss([rowB])
        await settle(model)
        #expect(await triage.dismissedMessages().count == 2)

        // One undo reverses the LAST action (B); A stays dismissed.
        model.undoLastDismiss()
        await settle(model)
        #expect(await triage.dismissedMessages().keys.sorted() == [rowA.draftKey])
    }

    // MARK: No success bar on a failed write

    @Test("a dismiss whose write throws shows no bar and registers no undo")
    internal func failedDismissShowsNoBar() async {
        let model = makeViewModel(triage: StowerFailingWriteTriageStore())
        let row = makeRow(chatID: "a", handle: "+14155550100")

        model.dismiss([row])
        await settle(model)

        #expect(model.undoBar == nil)
        #expect(model.undoManager.canUndo == false)
    }

    // MARK: I14 — interaction recording is semantic, one event per action

    @Test("dismiss records exactly one message_dismissed with the row's fields (I14)")
    internal func dismissRecordsEvent() async {
        let triage = StowerInMemoryTriageStore()
        let recorder = StowerInMemoryInteractionRecorder()
        let model = makeViewModel(triage: triage, recorder: recorder)
        let row = makeRow(chatID: "a", handle: "+14155550100")
        model.selectedTab = .maybeFollowUp

        model.dismiss([row])
        await settle(model)

        #expect(
            await recorder.recorded() == [
                .messageDismissed(
                    handleKey: row.draftKey,
                    messageGUID: row.lastMessageGUID,
                    boardTab: "maybe_follow_up",
                    occurredAt: triageFixedNow
                )
            ]
        )
    }

    @Test("mute records sender_muted from the board; the triage state mutates (I14)")
    internal func muteRecordsEvent() async {
        let triage = StowerInMemoryTriageStore()
        let recorder = StowerInMemoryInteractionRecorder()
        let model = makeViewModel(triage: triage, recorder: recorder)
        let row = makeRow(chatID: "a", handle: "+14155550100")

        model.mute(row)
        await settle(model)

        #expect(await triage.muted() == [row.draftKey])
        #expect(model.mutedCount == 1)
        #expect(
            await recorder.recorded() == [
                .senderMuted(handleKey: row.draftKey, surface: "board", occurredAt: triageFixedNow)
            ]
        )
    }

    @Test("unmute from the popover records sender_unmuted and restores the count (I14)")
    internal func unmuteRecordsEvent() async {
        let row = makeRow(chatID: "a", handle: "+14155550100")
        let triage = StowerInMemoryTriageStore(muted: [row.draftKey])
        let recorder = StowerInMemoryInteractionRecorder()
        let model = makeViewModel(triage: triage, recorder: recorder)
        await model.refreshMutedCount()
        #expect(model.mutedCount == 1)

        model.unmute(
            StowerMutedSender(
                key: row.draftKey,
                displayName: "Alex",
                hasResolvedName: true,
                isActivelyDismissed: false
            )
        )
        await settle(model)

        #expect(await triage.muted().isEmpty)
        #expect(model.mutedCount == 0)
        #expect(
            await recorder.recorded() == [
                .senderUnmuted(
                    handleKey: row.draftKey,
                    surface: "muted_senders",
                    occurredAt: triageFixedNow
                )
            ]
        )
    }

    @Test("a dropped recorder never blocks the dismiss (non-blocking — I14)")
    internal func recorderFailureDoesNotBlockDismiss() async {
        // A no-op recorder stands in for a failed live store (its `record` swallows):
        // the triage mutation and the bar must still happen.
        let triage = StowerInMemoryTriageStore()
        let model = makeViewModel(triage: triage, recorder: StowerNoOpInteractionRecorder())
        let row = makeRow(chatID: "a", handle: "+14155550100")

        model.dismiss([row])
        await settle(model)

        #expect(await triage.dismissedMessages().count == 1)
        #expect(model.undoBar?.count == 1)
    }

    // MARK: B2 — batch Select mode

    @Test("Dismiss N applies the whole selection as one batch and exits Select mode")
    internal func dismissSelectedBatchesAndExits() async {
        let triage = StowerInMemoryTriageStore()
        let dataSource = StowerSpyBoardDataSource()
        let rowA = uniqueRow("a")
        let rowB = uniqueRow("b")
        dataSource.loadModels = [StowerBoardModel(neglected: [rowA, rowB], ghosted: [])]
        let model = makeViewModel(dataSource: dataSource, triage: triage)

        model.load()
        await model.loadTaskHandle?.value
        model.enterSelectMode()
        model.selection = [rowA.id, rowB.id]
        model.dismissSelected()
        await settle(model)

        #expect(await triage.dismissedMessages().count == 2)
        #expect(model.isSelecting == false)
        #expect(model.selection.isEmpty)
        #expect(model.undoBar?.count == 2)
    }

    @Test("switching tabs exits Select mode and clears the per-lens selection (B2)")
    internal func tabSwitchExitsSelectMode() async {
        let model = makeViewModel(triage: StowerInMemoryTriageStore())
        model.enterSelectMode()
        model.selection = ["x", "y"]

        model.selectedTab = .maybeFollowUp

        #expect(model.isSelecting == false)
        #expect(model.selection.isEmpty)
    }

    // MARK: I12 — the muted count drives the zero-state line

    @Test("the muted count tracks mute then unmute, gating the zero-state line (I12)")
    internal func mutedCountDrivesZeroStateGate() async {
        let triage = StowerInMemoryTriageStore()
        let model = makeViewModel(triage: triage)
        let row = makeRow(chatID: "a", handle: "+14155550100")
        #expect(model.mutedCount == 0)

        model.mute(row)
        await settle(model)
        #expect(model.mutedCount == 1)

        model.unmute(
            StowerMutedSender(
                key: row.draftKey,
                displayName: "Alex",
                hasResolvedName: true,
                isActivelyDismissed: false
            )
        )
        await settle(model)
        #expect(model.mutedCount == 0)
    }
}
