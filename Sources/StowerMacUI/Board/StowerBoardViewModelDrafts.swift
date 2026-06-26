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
    /// an off-board draft stays in the store untouched (I-NeverDelete).
    internal func mergeDrafts(generation: Int) async {
        // A FAILED read must leave local state untouched — returning `[:]` here would
        // make the prune below wipe every visible draft on a transient hiccup (they're
        // still on disk). Distinguish failure from a genuine empty store: only prune
        // after a successful read.
        guard let fresh = try? await draftStore.all() else { return }
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
        commitDraft(key: key, body: body, cleared: cleared)
    }

    /// Persists one draft change, chained per key so the last edit wins.
    ///
    /// A cleared body `delete`s the row outright rather than `upsert`-ing an empty one
    /// (JC3) — explicit, even though the store's `upsert` already treats a blank body
    /// as a delete; the test locks that contract. A transient write failure retries
    /// with a bounded backoff: JC2 keeps the failure off the typing path (no error UI
    /// mid-edit), but the terminal write — the last edit before quit, with no next
    /// keystroke to retry it — must not silently vanish while the UI shows it saved.
    private func commitDraft(key: String, body: String, cleared: Bool) {
        let previous = inflightWrites[key]
        let limit = Self.draftWriteRetryLimit
        let backoff = Self.draftWriteRetryBackoff
        inflightWrites[key] = Task { [draftStore] in
            await previous?.value
            for attempt in 1...limit {
                do {
                    if cleared {
                        try await draftStore.delete(key: key)
                    } else {
                        try await draftStore.upsert(key: key, body: body)
                    }
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
