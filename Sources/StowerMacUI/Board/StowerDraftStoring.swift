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
        entries[key] = StowerDraftEntry(body: body, updatedAt: clock())
    }

    internal func delete(key: String) {
        entries[key] = nil
    }
}
