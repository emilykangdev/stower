import Foundation
import SwiftUI

/// The board view-model's draft surface: the corner composer's open/close
/// lifecycle, the Drafts-tab list, the write-through draft binding, and the "Reply
/// in Messages" bridge.
///
/// Split into this extension (the same split-across-files posture as
/// `StowerDebtBoardProvider`'s mechanics) so the primary file stays focused on the
/// load/refresh state machine. The reload-merge guard (`mergeDrafts`) stays in the
/// primary file with the load path it rides.
extension StowerBoardViewModel {
    /// The board row backing the open composer, or `nil` if none/off-board now.
    ///
    /// Resolving from the loaded board means a composer whose row vanished on a
    /// reload (or when the board cleared on a Contacts revoke) simply stops showing.
    internal var composerRow: StowerBoardRow? {
        guard let composerKey else { return nil }
        return boardRow(forDraftKey: composerKey)
    }

    /// The on-board conversations that have a draft, one card per `draftKey`.
    ///
    /// Built only from loaded board rows, so an off-board draft is never surfaced
    /// here (I-DraftsTabOnBoardOnly), and deduped so a conversation appearing in both
    /// lenses yields a single card.
    internal var onBoardDrafts: [StowerDraftCard] {
        guard let board else { return [] }
        var seen = Set<String>()
        var cards: [StowerDraftCard] = []
        for row in board.neglected + board.ghosted {
            guard let entry = drafts[row.draftKey], !seen.contains(row.draftKey) else { continue }
            seen.insert(row.draftKey)
            cards.append(StowerDraftCard(row: row, entry: entry))
        }
        return cards
    }

    /// Opens the corner composer for `row`, loading its read-only scrollback.
    ///
    /// Replaces any open composer (single-valued — I-ComposerSingle): the previous
    /// embedded thread is cancelled before the new one loads.
    internal func openComposer(for row: StowerBoardRow) {
        composerThread?.cancel()
        composerKey = row.draftKey
        let thread = makeThreadViewModel(for: row)
        composerThread = thread
        thread.onAppear()
    }

    /// Closes the composer and cancels its embedded thread load (no stale apply).
    internal func closeComposer() {
        composerThread?.cancel()
        composerThread = nil
        composerKey = nil
    }

    /// Merges the persisted drafts into `drafts` after a load.
    ///
    /// Skips the open composer's key so a background refresh never reverts an
    /// in-flight edit (I-ReloadPreservesEdit), and never calls the store's delete —
    /// an off-board draft stays in the store untouched (I-NeverDelete).
    internal func mergeDrafts(generation: Int) async {
        // `try?` is intentional: a rare store-read failure degrades to "no drafts to
        // merge this pass" (the in-memory `drafts` and the on-disk rows are untouched),
        // mirroring the engine's disposable-cache "a fault is a miss" posture.
        let fresh = (try? await draftStore.all()) ?? [:]
        guard generation == loadGeneration else { return }
        for (key, entry) in fresh where key != composerKey {
            drafts[key] = entry
        }
        let removed = drafts.keys.filter { fresh[$0] == nil && $0 != composerKey }
        for key in removed {
            drafts[key] = nil
        }
    }

    /// A write-through binding over the draft for `key`.
    ///
    /// The getter reads the current body; the setter updates `drafts` and persists
    /// the change immediately (JC2). Return is a newline in the editor, so there is
    /// no submit/blur commit step — every change is already on disk.
    internal func draftBinding(for key: String) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.drafts[key]?.body ?? "" },
            set: { [weak self] newBody in self?.setDraft(key: key, body: newBody) }
        )
    }

    /// Copies the draft, opens the conversation, and best-effort auto-pastes it.
    ///
    /// Never sends (JC5) — there is no send path to reach.
    internal func dropIntoMessages(_ row: StowerBoardRow) {
        dropper.drop(text: drafts[row.draftKey]?.body ?? "", deepLink: row.deepLink)
    }

    /// Drains every in-flight write-through upsert, so a graceful quit loses nothing.
    ///
    /// Called from `applicationShouldTerminate` (JC2); never reached by `cancel()`.
    internal func flushAll() async {
        for task in inflightWrites.values {
            await task.value
        }
    }

    /// Updates the local draft and writes the change through to the store.
    private func setDraft(key: String, body: String) {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[key] = nil
        } else {
            drafts[key] = StowerDraftEntry(body: body, updatedAt: clock())
        }
        commitDraft(key: key, body: body)
    }

    /// Persists one draft change, chained per key so the last edit wins.
    private func commitDraft(key: String, body: String) {
        let previous = inflightWrites[key]
        inflightWrites[key] = Task { [draftStore] in
            await previous?.value
            // `try?` is intentional (JC2 RPO): the body is already in `drafts`, and a
            // rare write failure is retried by the next keystroke's commit — never
            // surfaced as an error mid-typing.
            try? await draftStore.upsert(key: key, body: body)
        }
    }

    /// The loaded board row for `draftKey`, searching both lenses.
    private func boardRow(forDraftKey key: String) -> StowerBoardRow? {
        guard let board else { return nil }
        return board.neglected.first { $0.draftKey == key }
            ?? board.ghosted.first { $0.draftKey == key }
    }
}
