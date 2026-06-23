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

    /// Creates a draft record.
    ///
    /// - Parameters:
    ///   - body: The draft text.
    ///   - updatedAt: The last-write timestamp.
    public init(body: String, updatedAt: Date) {
        self.body = body
        self.updatedAt = updatedAt
    }
}
