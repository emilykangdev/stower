import Foundation
import StowerMessages
import Synchronization
import Testing

@testable import StowerMacUI

/// The board view-model's draft behaviors: write-through persistence
/// (I-WriteThrough), reload-preserves-edit (I-ReloadPreservesEdit), never-prune
/// off-board (I-NeverDelete), on-board-only Drafts tab (I-DraftsTabOnBoardOnly),
/// single composer (I-ComposerSingle), embedded-thread lifecycle
/// (I-ComposerThreadLifecycle), and composer-closes-on-revoke
/// (I-ComposerClosesOnContactsRevoke).
///
/// Driven by `StowerSpyBoardDataSource` + an in-memory `StowerDraftStoring`.
@MainActor
@Suite internal struct StowerBoardViewModelDraftsTests {
    private func makeViewModel(
        _ spy: StowerSpyBoardDataSource,
        draftStore: any StowerDraftStoring = StowerInMemoryDraftStore(),
        contacts: StowerContactsAccess = .denied
    ) -> StowerBoardViewModel {
        StowerBoardViewModel(
            dataSource: spy,
            draftStore: draftStore,
            contacts: contacts,
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
            monogram: "?",
            summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
            ageInDays: 1,
            deepLink: URL(string: "sms:\(handle)")
        )
    }

    @Test("a binding edit persists write-through (I-WriteThrough)")
    internal func writeThroughPersists() async {
        let store = StowerInMemoryDraftStore()
        let spy = StowerSpyBoardDataSource()
        let row = draftRow(chatID: "c1", handle: "alice")
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        model.draftBinding(for: row.draftKey).wrappedValue = "call back"
        await model.flushAll()

        #expect(await store.all()[row.draftKey]?.body == "call back")
        #expect(model.drafts[row.draftKey]?.body == "call back")
    }

    @Test("a reload while editing does not revert the in-flight edit (I-ReloadPreservesEdit)")
    internal func reloadPreservesEdit() async {
        let store = StowerInMemoryDraftStore()
        let spy = StowerSpyBoardDataSource()
        let row = draftRow(chatID: "c1", handle: "alice")
        let oneRow = StowerBoardModel(neglected: [row], ghosted: [])
        spy.loadModels = [oneRow, oneRow]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        model.openComposer(for: row)
        model.draftBinding(for: row.draftKey).wrappedValue = "new text"
        await model.flushAll()
        // The store diverges to an external value; a reload must NOT clobber the edit.
        try? await store.upsert(key: row.draftKey, body: "external")

        model.load()
        await model.loadTaskHandle?.value

        #expect(model.drafts[row.draftKey]?.body == "new text")
    }

    @Test("an off-board draft is never pruned by a load (I-NeverDelete)")
    internal func offBoardDraftPreserved() async {
        let store = StowerInMemoryDraftStore(entries: [
            "raw:offboard": StowerDraftEntry(body: "keep me", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        let row = draftRow(chatID: "c1", handle: "alice")
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        #expect(await store.all()["raw:offboard"]?.body == "keep me")
        #expect(model.onBoardDrafts.contains { $0.id == "raw:offboard" } == false)
    }

    @Test("the Drafts tab lists only on-board drafts, deduped (I-DraftsTabOnBoardOnly)")
    internal func draftsTabOnBoardOnly() async {
        let onBoard = draftRow(chatID: "c1", handle: "alice")
        let store = StowerInMemoryDraftStore(entries: [
            onBoard.draftKey: StowerDraftEntry(body: "hi alice", updatedAt: Date()),
            "raw:bob": StowerDraftEntry(body: "off board", updatedAt: Date())
        ])
        let spy = StowerSpyBoardDataSource()
        // The same conversation in both lenses must dedupe to one card.
        spy.loadModels = [StowerBoardModel(neglected: [onBoard], ghosted: [onBoard])]
        let model = makeViewModel(spy, draftStore: store)
        model.load()
        await model.loadTaskHandle?.value

        #expect(model.onBoardDrafts.map(\.id) == [onBoard.draftKey])
    }

    @Test("opening a second composer replaces the first (I-ComposerSingle)")
    internal func composerSingle() async {
        let spy = StowerSpyBoardDataSource()
        let rowA = draftRow(chatID: "a", handle: "alice")
        let rowB = draftRow(chatID: "b", handle: "bob")
        spy.loadModels = [StowerBoardModel(neglected: [rowA, rowB], ghosted: [])]
        let model = makeViewModel(spy)
        model.load()
        await model.loadTaskHandle?.value

        model.openComposer(for: rowA)
        model.openComposer(for: rowB)
        #expect(model.composerKey == rowB.draftKey)
        #expect(model.composerRow?.id == "b")
    }

    @Test("the composer resolves the clicked thread, not its same-handle draftKey sibling")
    internal func composerResolvesByChatIDNotDraftKey() async {
        // Same number, two threads (iMessage + SMS) — one shared draftKey, distinct
        // chatIDs (A2). The composer must show the one that was clicked.
        let handle = "+15551112222"
        let iMessage = draftRow(chatID: "imessage", handle: handle)
        let sms = draftRow(chatID: "sms", handle: handle)
        #expect(iMessage.draftKey == sms.draftKey)
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [StowerBoardModel(neglected: [iMessage, sms], ghosted: [])]
        let model = makeViewModel(spy)
        model.load()
        await model.loadTaskHandle?.value

        model.openComposer(for: sms)
        #expect(model.composerRow?.chatID == "sms")
        #expect(model.composerKey == sms.draftKey)
    }

    @Test("opening loads the embedded thread; closing cancels it (I-ComposerThreadLifecycle)")
    internal func composerThreadLifecycle() async {
        let spy = StowerSpyBoardDataSource()
        let row = draftRow(chatID: "c1", handle: "alice")
        spy.loadModels = [StowerBoardModel(neglected: [row], ghosted: [])]
        let model = makeViewModel(spy)
        model.load()
        await model.loadTaskHandle?.value

        model.openComposer(for: row)
        #expect(model.composerThread != nil)
        #expect(model.composerThread?.loadTaskHandle != nil)

        model.closeComposer()
        #expect(model.composerThread == nil)
        #expect(model.composerKey == nil)
    }

    @Test("revoking Contacts closes the composer (I-ComposerClosesOnContactsRevoke)")
    internal func revokeClosesComposer() async {
        let authorized = Mutex(true)
        let contacts = StowerContactsAccess(
            status: { authorized.withLock { $0 } ? .authorized : .denied },
            request: { false }
        )
        let spy = StowerSpyBoardDataSource()
        let row = draftRow(chatID: "c1", handle: "alice")
        let oneRow = StowerBoardModel(neglected: [row], ghosted: [])
        spy.loadModels = [oneRow, oneRow]
        let model = makeViewModel(spy, contacts: contacts)
        model.load()
        await model.loadTaskHandle?.value

        model.openComposer(for: row)
        #expect(model.composerKey == row.draftKey)

        authorized.withLock { $0 = false }
        model.onAppBecameActive()

        #expect(model.composerKey == nil)
        #expect(model.composerThread == nil)
    }
}
