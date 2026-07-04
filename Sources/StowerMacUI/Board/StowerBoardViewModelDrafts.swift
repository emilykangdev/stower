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
    /// Resolves by the stable `chatID` (never `draftKey`), so when two same-number
    /// threads share a `draftKey` the composer always shows the exact thread that was
    /// clicked. Re-resolving from the loaded board means a composer whose row vanished
    /// on a reload (or when the board cleared on a Contacts revoke) simply stops
    /// showing, and a refresh surfaces the row's fresh age/name.
    internal var composerRow: StowerBoardRow? {
        guard let composerChatID, let board else { return nil }
        return board.neglected.first { $0.chatID == composerChatID }
            ?? board.ghosted.first { $0.chatID == composerChatID }
    }

    /// The on-board conversations that have an ACTIVE draft, one card per `draftKey`.
    ///
    /// Built only from loaded board rows, so an off-board draft is never surfaced
    /// here (I-DraftsTabOnBoardOnly), and deduped so a conversation appearing in both
    /// lenses yields a single card. A resolved draft (`resolvedAt != nil`) is filtered
    /// out — one of the three surfaces (with `activeDraftPreview` and the composer
    /// binding getter) that must all hide a resolved draft.
    internal var onBoardDrafts: [StowerDraftCard] {
        guard let board else { return [] }
        var seen = Set<String>()
        var cards: [StowerDraftCard] = []
        for row in board.neglected + board.ghosted {
            guard let entry = drafts[row.draftKey], entry.resolvedAt == nil,
                !seen.contains(row.draftKey)
            else { continue }
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
        composerChatID = row.chatID
        let thread = makeThreadViewModel(for: row)
        composerThread = thread
        thread.onAppear()
    }

    /// Closes the composer and cancels its embedded thread load (no stale apply).
    internal func closeComposer() {
        composerThread?.cancel()
        composerThread = nil
        composerKey = nil
        composerChatID = nil
    }

    /// Merges the persisted drafts into `drafts` after a load.
    ///
    /// Skips the open composer's key so a background refresh never reverts an
    /// in-flight edit (I-ReloadPreservesEdit), and never calls the store's delete —
    /// an off-board draft stays in the store untouched (I-NeverDelete). Also guards a
    /// locally-resolved entry whose `markSent` write is still in flight (I10): a
    /// reload fed stale (`resolvedAt == nil`) fresh data for that key must NOT revert
    /// the just-resolved card while the durable write hasn't landed yet.
    internal func mergeDrafts(generation: Int) async {
        // A FAILED read must leave local state untouched — returning `[:]` here would
        // make the prune below wipe every visible draft on a transient hiccup (they're
        // still on disk). Distinguish failure from a genuine empty store: only prune
        // after a successful read.
        guard let fresh = try? await draftStore.all() else { return }
        guard generation == loadGeneration else { return }
        for (key, entry) in fresh where key != composerKey {
            if drafts[key]?.resolvedAt != nil, entry.resolvedAt == nil, inflightWrites[key] != nil {
                // Keep the in-flight resolve: a queued markSent hasn't landed yet, so
                // the stale fresh row must not un-resolve the card out from under it.
                continue
            }
            drafts[key] = entry
        }
        let removed = drafts.keys.filter { fresh[$0] == nil && $0 != composerKey }
        for key in removed {
            drafts[key] = nil
        }
    }

    /// A write-through binding over the draft for `key`.
    ///
    /// The getter reads the current body, but returns `""` when the entry is
    /// resolved (T-ReactivateBody): the user has already sent it, so its old body
    /// is never resurfaced for editing on reopen — the body is kept only so D2's
    /// undo can restore it. The setter updates `drafts` and persists the change
    /// immediately (JC2); typing there reactivates the draft as a brand-new one.
    /// Return is a newline in the editor, so there is no submit/blur commit step —
    /// every change is already on disk.
    internal func draftBinding(for key: String) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.activeDraftPreview(key: key) ?? "" },
            set: { [weak self] newBody in self?.setDraft(key: key, body: newBody) }
        )
    }

    /// The draft body for `key` iff it's active, or `nil` when resolved/absent.
    ///
    /// The single gate all three active-draft surfaces (Drafts tab `onBoardDrafts`,
    /// composer `draftBinding` getter, inline `StowerNoReplyRowView` preview) read
    /// through, so a resolved draft can never show its stale body anywhere.
    internal func activeDraftPreview(key: String) -> String? {
        guard let entry = drafts[key], entry.resolvedAt == nil else { return nil }
        return entry.body
    }

    /// Copies the draft, opens the conversation, and best-effort auto-pastes it.
    ///
    /// Never sends (JC5) — there is no send path to reach. Reads the ACTIVE body
    /// only (not the raw store entry): re-clicking "Reply in Messages" after a
    /// resolve must never paste a resolved draft's stale body.
    internal func dropIntoMessages(_ row: StowerBoardRow) {
        dropper.drop(text: activeDraftPreview(key: row.draftKey) ?? "", deepLink: row.deepLink)
    }

    /// Drains every in-flight write-through upsert AND the in-flight triage action, so
    /// a graceful quit loses neither a draft nor a just-issued dismiss/mute/unmute.
    ///
    /// Called from `applicationShouldTerminate` (JC2); never reached by `cancel()`.
    internal func flushAll() async {
        for task in inflightWrites.values {
            await task.value
        }
        // The triage chain ends each action with a durable write before its reload, so
        // awaiting it guarantees a dismiss/mute issued moments before ⌘Q is persisted.
        await triageTask?.value
    }

    /// Updates the local draft and writes the change through to the store.
    private func setDraft(key: String, body: String) {
        let cleared = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        drafts[key] = cleared ? nil : StowerDraftEntry(body: body, updatedAt: clock())
        enqueueDraftWrite(key: key) { [draftStore] in
            if cleared {
                try await draftStore.delete(key: key)
            } else {
                try await draftStore.upsert(key: key, body: body)
            }
        }
    }

    /// Marks the draft for `row` sent (Flow 1 composer / Flow 2 checkmark, D1/D2).
    ///
    /// A no-op if the draft is missing or already resolved. Updates the local entry
    /// immediately (keeping the body), closes the composer if it's the one open for
    /// this row (D1 — never a side effect of the field clearing, an explicit call),
    /// presents the reused `StowerDismissUndoBar` (D2), and enqueues the durable
    /// write chained on this key's `inflightWrites` (I11) so a keystroke-upsert
    /// already queued for this key cannot land after and reset `resolved_at = NULL`
    /// on disk.
    internal func markSent(_ row: StowerBoardRow) {
        let key = row.draftKey
        guard let entry = drafts[key], entry.resolvedAt == nil else { return }
        drafts[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: clock()
        )
        if composerChatID == row.chatID {
            closeComposer()
        }
        presentDraftResolveUndoBar(for: row)
        enqueueDraftWrite(key: key) { [draftStore] in
            try await draftStore.markSent(key: key)
        }
    }

    /// Presents the single reused `StowerDismissUndoBar` slot (D2/JC7) for a draft
    /// resolve — bumping the same monotonic sequence a dismiss bar uses (so either
    /// action restarts the one drain timer) and recording `row` as the state's
    /// `pendingDraftResolve`, so `undoLastDismiss` routes its Undo to `unmarkSent`
    /// instead of the triage `UndoManager` stack.
    private func presentDraftResolveUndoBar(for row: StowerBoardRow) {
        undoBarSequence += 1
        undoBar = StowerDismissUndoBarState(id: undoBarSequence, count: 1, pendingDraftResolve: row)
    }

    /// Reverses a "Mark as sent" (the reused undo bar's Undo, D2): restores the
    /// local entry to active and enqueues the durable `unmarkSent`, chained on the
    /// same per-key queue as every other draft write.
    internal func unmarkSent(_ row: StowerBoardRow) {
        let key = row.draftKey
        guard let entry = drafts[key] else { return }
        drafts[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: nil
        )
        enqueueDraftWrite(key: key) { [draftStore] in
            try await draftStore.unmarkSent(key: key)
        }
    }

    /// Persists one draft change, chained per key so the last-issued write wins.
    ///
    /// Every mutation to a key's row — `upsert`, `delete`, `markSent`,
    /// `unmarkSent` — funnels through here (I11), so a write queued earlier for
    /// this key always lands before one queued later, never the reverse. A
    /// transient write failure retries with a bounded backoff: JC2 keeps the
    /// failure off the typing path (no error UI mid-edit), but the terminal write
    /// — the last one before quit, with no next keystroke to retry it — must not
    /// silently vanish while the UI shows it saved.
    private func enqueueDraftWrite(key: String, op: @escaping @Sendable () async throws -> Void) {
        let previous = inflightWrites[key]
        let limit = Self.draftWriteRetryLimit
        let backoff = Self.draftWriteRetryBackoff
        inflightWrites[key] = Task {
            await previous?.value
            for attempt in 1...limit {
                do {
                    try await op()
                    return
                } catch {
                    guard attempt < limit else { return }
                    try? await Task.sleep(for: backoff)
                }
            }
        }
    }

    /// How many times a write-through draft change retries before giving up.
    private static let draftWriteRetryLimit = 3

    /// The backoff between write-through retries (rides out a transient lock /
    /// briefly-full disk without blocking a graceful quit's `flushAll`).
    private static let draftWriteRetryBackoff: Duration = .milliseconds(50)
}
