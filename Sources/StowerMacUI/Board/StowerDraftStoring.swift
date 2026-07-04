import Foundation

/// One draft's app-facing payload: its body and when it was last edited.
///
/// The app-owned mirror of the engine's `StowerDraftRecord`, adapted at the
/// composition seam so the view layer never imports `StowerMessages`.
internal struct StowerDraftEntry: Sendable, Equatable {
    /// The draft text, verbatim.
    internal let body: String

    /// When the draft was last written (drives the Drafts tab's "edited …" label).
    internal let updatedAt: Date

    /// When the user marked this draft sent, or `nil` while still active.
    ///
    /// `nil` = active (shown in the Drafts tab, the composer, and the inline
    /// preview); set = resolved (hidden from all three, row kept for D2's undo).
    internal let resolvedAt: Date?

    /// Creates a draft entry.
    internal init(body: String, updatedAt: Date, resolvedAt: Date? = nil) {
        self.body = body
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }
}

/// One Drafts-tab entry: an on-board conversation paired with its draft.
///
/// Identity is the `draftKey`, so the Drafts list diffs by conversation. Built only
/// from loaded board rows, so it never surfaces an off-board draft.
internal struct StowerDraftCard: Identifiable, Equatable {
    /// The board row whose conversation this draft belongs to.
    internal let row: StowerBoardRow

    /// The draft body + last-edited time.
    internal let entry: StowerDraftEntry

    /// The list identity: the stable draft key.
    internal var id: String { row.draftKey }
}

/// The app-owned boundary the board view-model persists drafts through.
///
/// Mirrors how `StowerBoardDataSource` fronts the engine: the view layer depends on
/// this app-owned protocol, and the composition adapts the precious
/// `StowerMessages.StowerDraftStore` to it. So the view-model stays free of the
/// engine import (precheck 6b) while the durability lives in the data layer.
internal protocol StowerDraftStoring: Sendable {
    /// Every stored draft, keyed by `StowerDraftKey`.
    func all() async throws -> [String: StowerDraftEntry]

    /// Inserts or replaces the draft for `key`; a blank/whitespace body deletes it.
    func upsert(key: String, body: String) async throws

    /// Deletes the draft for `key`; a no-op when none exists.
    func delete(key: String) async throws

    /// Marks the draft for `key` sent: sets `resolvedAt` to now, keeping the body.
    ///
    /// An additive update only — it must never route through `delete`, so the body
    /// `unmarkSent` needs to restore is never destroyed. A no-op when no draft
    /// exists for `key`.
    func markSent(key: String) async throws

    /// Un-resolves the draft for `key` (the "Mark as sent" undo): clears
    /// `resolvedAt` back to `nil`, keeping the body untouched. A no-op when no
    /// draft exists for `key`.
    func unmarkSent(key: String) async throws
}

/// A volatile draft store for previews and tests ONLY.
///
/// Never used in production (the composition opens the precious on-disk
/// `StowerDraftStore`): a volatile store would silently lose drafts. It mirrors the
/// real store's blank-body-deletes contract so a test double behaves faithfully.
internal actor StowerInMemoryDraftStore: StowerDraftStoring {
    private var entries: [String: StowerDraftEntry]
    private let clock: @Sendable () -> Date

    /// Creates an in-memory store, optionally pre-seeded.
    internal init(
        entries: [String: StowerDraftEntry] = [:],
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.entries = entries
        self.clock = clock
    }

    internal func all() -> [String: StowerDraftEntry] {
        entries
    }

    internal func upsert(key: String, body: String) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            entries[key] = nil
            return
        }
        // A body write always reactivates: resolvedAt resets to nil, mirroring the
        // real store's upsert contract.
        entries[key] = StowerDraftEntry(body: body, updatedAt: clock())
    }

    internal func delete(key: String) {
        entries[key] = nil
    }

    internal func markSent(key: String) {
        guard let entry = entries[key] else { return }
        entries[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: clock()
        )
    }

    internal func unmarkSent(key: String) {
        guard let entry = entries[key] else { return }
        entries[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: nil
        )
    }
}
