import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// The board view-model's mark-as-sent undo behaviors (D2).
///
/// Covers the reused `StowerDismissUndoBar`'s Undo button, ⌘Z driving the shared
/// `UndoManager` directly (`StowerMacApp.performUndo` — NOT `undoLastDismiss`),
/// redo, and the flaky-write retry parity for `markSent`/`unmarkSent` (I12/I13).
///
/// Split out from `StowerBoardViewModelDraftResolveTests` (which covers the
/// resolve-side filtering/composer-close behaviors) to stay under the
/// file/type-length gate — this file is the undo-specific sibling.
@MainActor
@Suite internal struct StowerBoardViewModelDraftUndoTests {
    private func makeViewModel(
        _ spy: StowerSpyBoardDataSource,
        draftStore: any StowerDraftStoring = StowerInMemoryDraftStore(),
        undoManager: UndoManager = UndoManager()
    ) -> StowerBoardViewModel {
        StowerBoardViewModel(
            dataSource: spy,
            draftStore: draftStore,
            undoManager: undoManager,
            onFailure: { _ in },
            sleep: { _ in }
        )
    }

    /// A row whose `draftKey` derives from a chosen handle (distinct keys per row).
    private func draftRow(chatID: String, handle: String) -> StowerBoardRow {
        StowerBoardRow(
            chatID: chatID,
            counterpart: handle,
            counterpartHandle: handle,
            draftKey: StowerDraftKey.derive(forHandle: handle),
            lastMessageGUID: "guid-\(chatID)",
            lastMessageTimestamp: Date(timeIntervalSince1970: 1_000_000),
            monogram: "?",
            summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
            ageInDays: 1,
            deepLink: URL(string: "sms:\(handle)")
        )
    }

    // MARK: I13 (VM-level) — markSent then unmarkSent (D2 undo) round-trips

    @Test("unmarkSent restores the local entry to active, keeping the body (I13)")
    internal func unmarkSentRestoresActive() async {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerInMemoryDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        model.markSent(row)
        #expect(model.drafts[row.draftKey]?.resolvedAt != nil)

        model.unmarkSent(row)
        await model.flushAll()

        #expect(model.drafts[row.draftKey]?.resolvedAt == nil)
        #expect(model.drafts[row.draftKey]?.body == "call back")
        #expect(try await store.all()[row.draftKey]?.resolvedAt == nil)
    }

    @Test("the reused undo bar's Undo (undoLastDismiss) reverses a draft resolve (D2)")
    internal func undoBarUndoesDraftResolve() async {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerInMemoryDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        model.markSent(row)
        #expect(model.undoBar != nil)
        // Codex P2 regression: the bar must render/announce as a resolve, not a
        // dismiss ("Dismissed" would be wrong copy for "Mark as sent").
        #expect(model.undoBar?.kind == .markedSent)

        model.undoLastDismiss()
        await model.flushAll()

        #expect(model.drafts[row.draftKey]?.resolvedAt == nil)
        #expect(model.undoBar == nil)
        #expect(try await store.all()[row.draftKey]?.resolvedAt == nil)
    }

    @Test("Cmd-Z (undoManager.undo directly, not undoLastDismiss) also reverses a draft resolve")
    internal func cmdZUndoesDraftResolve() async {
        // Regression test for a Codex P2 finding: the app target's ⌘Z calls
        // `undoManager.undo()` DIRECTLY (StowerMacApp.performUndo), never
        // `undoLastDismiss`. markSent must register on that same UndoManager so
        // ⌘Z reverses the resolve, not merely the bar's Undo button.
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerInMemoryDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        let undoManager = UndoManager()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store, undoManager: undoManager)
        model.load()
        await model.loadTaskHandle?.value

        model.markSent(row)
        #expect(model.drafts[row.draftKey]?.resolvedAt != nil)

        undoManager.undo()
        await model.flushAll()

        #expect(model.drafts[row.draftKey]?.resolvedAt == nil)
        #expect(try await store.all()[row.draftKey]?.resolvedAt == nil)
    }

    @Test("redoing a draft resolve after Cmd-Z re-resolves it")
    internal func redoReResolvesDraft() async {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerInMemoryDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        let undoManager = UndoManager()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store, undoManager: undoManager)
        model.load()
        await model.loadTaskHandle?.value

        model.markSent(row)
        undoManager.undo()
        await model.flushAll()
        #expect(model.drafts[row.draftKey]?.resolvedAt == nil)

        undoManager.redo()
        await model.flushAll()

        #expect(model.drafts[row.draftKey]?.resolvedAt != nil)
        #expect(try await store.all()[row.draftKey]?.resolvedAt != nil)
    }

    // MARK: I12 — the flaky test double covers markSent/unmarkSent + their retry

    @Test("a transient markSent write failure is retried, landing resolved_at (I12)")
    internal func markSentTransientFailureIsRetried() async throws {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerFlakyDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        await store.setFailNextWrites(1)
        model.markSent(row)
        await model.flushAll()

        #expect(try await store.all()[row.draftKey]?.resolvedAt != nil)
    }

    @Test("a transient unmarkSent write failure is retried, clearing resolved_at (I12)")
    internal func unmarkSentTransientFailureIsRetried() async throws {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerFlakyDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        model.markSent(row)
        await model.flushAll()

        await store.setFailNextWrites(1)
        model.unmarkSent(row)
        await model.flushAll()

        #expect(try await store.all()[row.draftKey]?.resolvedAt == nil)
    }
}
