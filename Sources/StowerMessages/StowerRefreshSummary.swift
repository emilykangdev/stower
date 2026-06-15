import Foundation

/// What a background `refreshJudgments` pass changed in the verdict cache.
///
/// The app reads this to decide whether to reload the board: a non-empty
/// `changedChatIDs` means newly backfilled language-model verdicts will upgrade
/// those rows on the next `loadDebtBoard`.
public struct StowerRefreshSummary: Sendable, Equatable {
    /// The chat identities whose cached verdict was written or updated.
    public let changedChatIDs: [String]

    /// How many conversations got a new or updated verdict.
    public var changedCount: Int { changedChatIDs.count }

    /// Creates a refresh summary.
    public init(changedChatIDs: [String]) {
        self.changedChatIDs = changedChatIDs
    }
}
