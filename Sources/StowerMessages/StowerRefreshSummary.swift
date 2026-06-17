import Foundation

/// What a background `refreshJudgments` pass produced — completion metadata the
/// app reads once when the pass ends, not live streaming progress.
///
/// The app drives two separate signals off one summary: it clears its cold-start
/// loading screen when `judgedCount + failedCount == totalCount` (never
/// `judgedCount == totalCount` — a permanently failing record would hang the
/// spinner), and it reloads the board via `loadDebtBoard` only when
/// `changedChatIDs` is non-empty.
public struct StowerRefreshSummary: Sendable, Equatable {
    /// Chat IDs whose current-key trusted verdict was written or changed this pass.
    ///
    /// Includes a first-ever trusted write, not only semantic changes (a first
    /// write must trigger a reload or cold-start rows never appear). Drives a
    /// board reload.
    public let changedChatIDs: [String]

    /// Records with a trusted verdict in cache now (existing hits + new writes).
    public let judgedCount: Int

    /// Records this pass attempted but couldn't persist a trusted verdict for.
    public let failedCount: Int

    /// Records in the current snapshot.
    public let totalCount: Int

    /// Count of `changedChatIDs`; retained from the prior summary (non-breaking).
    public var changedCount: Int { changedChatIDs.count }

    /// Creates a refresh summary.
    public init(changedChatIDs: [String], judgedCount: Int, failedCount: Int, totalCount: Int) {
        self.changedChatIDs = changedChatIDs
        self.judgedCount = judgedCount
        self.failedCount = failedCount
        self.totalCount = totalCount
    }
}
