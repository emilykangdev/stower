import Foundation

/// One stored draft's payload: its body and when it was last written.
///
/// Returned (keyed by `StowerDraftKey`) from `StowerDraftStore.all` so a caller can
/// both render the draft and show when it was last edited. The draft key is the
/// dictionary key, so it is not repeated here.
public struct StowerDraftRecord: Sendable, Equatable {
    /// The draft text, verbatim (internal whitespace and newlines preserved).
    public let body: String

    /// When the draft was last upserted (set by the store on every write).
    public let updatedAt: Date

    /// When the user marked this draft sent, or `nil` while still active.
    ///
    /// `nil` = active (shown everywhere a draft appears); set = resolved (hidden
    /// from active surfaces, row kept — soft-resolve, never deleted). Set only by
    /// `StowerDraftStore.markSent`; cleared by a body `upsert` (reactivation) or
    /// `unmarkSent` (undo).
    public let resolvedAt: Date?

    /// Creates a draft record.
    ///
    /// - Parameters:
    ///   - body: The draft text.
    ///   - updatedAt: The last-write timestamp.
    ///   - resolvedAt: When the draft was marked sent, or `nil` if active.
    public init(body: String, updatedAt: Date, resolvedAt: Date? = nil) {
        self.body = body
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }
}
