import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// The board view-model's "Mark as sent" draft-resolve behaviors: the Drafts-tab
/// filter (I6), the inline/composer active-body gate (I7), the local resolve +
/// composer-close on mark-sent (I8/D1, including the shared-`draftKey` sibling
/// case), the reload race guard (I10), and the per-key write-ordering guarantee
/// (I11).
///
/// Sibling to `StowerBoardViewModelDraftsTests` (pre-existing draft
/// write-through/composer-lifecycle contract) and
/// `StowerBoardViewModelDraftUndoTests` (the D2 undo/⌘Z/redo/I12/I13 behaviors);
/// split out to stay under the file/type length gate.
@MainActor
@Suite internal struct StowerBoardViewModelDraftResolveTests {
    private func makeViewModel(
        _ spy: StowerSpyBoardDataSource,
        draftStore: any StowerDraftStoring = StowerInMemoryDraftStore()
    ) -> StowerBoardViewModel {
        StowerBoardViewModel(
            dataSource: spy,
            draftStore: draftStore,
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

    // MARK: I6 — onBoardDrafts excludes resolved drafts

    @Test("onBoardDrafts excludes a resolved draft, keeping the active one (I6)")
    internal func onBoardDraftsExcludesResolved() async {
        let active = draftRow(chatID: "c1", handle: "alice")
        let resolved = draftRow(chatID: "c2", handle: "bob")
        let store = StowerInMemoryDraftStore(entries: [
            active.draftKey: StowerDraftEntry(body: "still drafting", updatedAt: Date()),
            resolved.draftKey: StowerDraftEntry(
                body: "already sent",
                updatedAt: Date(),
                resolvedAt: Date()
            )
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [active, resolved], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        #expect(model.onBoardDrafts.map(\.id) == [active.draftKey])
    }

    // MARK: I7 — activeDraftPreview returns nil for resolved, body for active

    @Test("activeDraftPreview returns nil for a resolved draft, body for an active one (I7)")
    internal func activeDraftPreviewFiltersResolved() async {
        let active = draftRow(chatID: "c1", handle: "alice")
        let resolved = draftRow(chatID: "c2", handle: "bob")
        let store = StowerInMemoryDraftStore(entries: [
            active.draftKey: StowerDraftEntry(body: "still drafting", updatedAt: Date()),
            resolved.draftKey: StowerDraftEntry(
                body: "already sent",
                updatedAt: Date(),
                resolvedAt: Date()
            )
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [active, resolved], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        #expect(model.activeDraftPreview(key: active.draftKey) == "still drafting")
        #expect(model.activeDraftPreview(key: resolved.draftKey) == nil)
    }

    // MARK: I8 — markSent(_:) sets the local entry's resolvedAt and keeps the body

    @Test("markSent sets the local entry's resolvedAt and keeps the body (I8)")
    internal func markSentSetsLocalResolvedAt() async {
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
        #expect(model.drafts[row.draftKey]?.body == "call back")
        await model.flushAll()
        #expect(try await store.all()[row.draftKey]?.resolvedAt != nil)
    }

    @Test("markSent closes the composer when it's the open one (D1)")
    internal func markSentClosesOpenComposer() async {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerInMemoryDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value
        model.openComposer(for: row)
        #expect(model.composerKey == row.draftKey)

        model.markSent(row)

        #expect(model.composerKey == nil)
        #expect(model.composerThread == nil)
    }

    @Test(
        "markSent closes the composer for a same-key sibling row (shared draftKey, distinct chatID)"
    )
    internal func markSentClosesComposerForSharedKeySibling() async {
        // Same number, two threads (iMessage + SMS) — one shared draftKey, distinct
        // chatIDs (A2). The composer is open on the iMessage thread; resolving via
        // the Drafts-tab card for the SMS sibling (same draftKey) must still close
        // it — the open composer's editor reads by the shared key, so leaving it
        // open would show a blanked field for a draft that still "exists" per
        // composerChatID, misreading as data loss (the exact case D1 guards against).
        let handle = "+15551112222"
        let iMessage = draftRow(chatID: "imessage", handle: handle)
        let sms = draftRow(chatID: "sms", handle: handle)
        #expect(iMessage.draftKey == sms.draftKey)
        let store = StowerInMemoryDraftStore(entries: [
            iMessage.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [iMessage, sms], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value
        model.openComposer(for: iMessage)
        #expect(model.composerChatID == "imessage")

        // Resolve via the SIBLING row (SMS) — different chatID, same draftKey.
        model.markSent(sms)

        #expect(model.composerKey == nil)
        #expect(model.composerThread == nil)
    }

    // MARK: I10 — a Flow-2 markSent survives a stale mergeDrafts reload race

    @Test(
        "a resolved draft (composer closed) survives a reload fed stale active data (I10)"
    )
    internal func markSentSurvivesStaleReloadRace() async throws {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerFlakyDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        let oneRow = StowerBoardModel(neglected: [row], ghosted: [])
        spy.loadModels = [oneRow, oneRow]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        // Resolve via the checkmark (composer stays closed — composerKey is nil).
        model.markSent(row)
        #expect(model.drafts[row.draftKey]?.resolvedAt != nil)

        // A background reload races ahead of the durable markSent write landing —
        // the store still reports the stale, active (resolvedAt == nil) row.
        model.load()
        await model.loadTaskHandle?.value

        // The in-flight-resolve guard in mergeDrafts must keep the card resolved.
        #expect(model.drafts[row.draftKey]?.resolvedAt != nil)
        #expect(model.onBoardDrafts.isEmpty)

        // Let the queued write actually land, then confirm the store agrees.
        await model.flushAll()
        #expect(try await store.all()[row.draftKey]?.resolvedAt != nil)
    }

    // MARK: I11 — markSent is chained on inflightWrites; ordering can't invert

    @Test(
        "a keystroke upsert queued before markSent cannot land after and reset resolved_at (I11)"
    )
    internal func markSentOrderingSurvivesQueuedUpsert() async {
        let row = draftRow(chatID: "c1", handle: "alice")
        let store = StowerInMemoryDraftStore(entries: [
            row.draftKey: StowerDraftEntry(body: "call back", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        // Queue a keystroke upsert, then immediately markSent — both chain on the
        // same per-key inflightWrites queue, so the upsert must land BEFORE
        // markSent's UPDATE, never after (which would revert resolved_at to NULL).
        model.draftBinding(for: row.draftKey).wrappedValue = "call back soon"
        model.markSent(row)
        await model.flushAll()

        let record = await store.all()[row.draftKey]
        #expect(record?.resolvedAt != nil)
    }

}
