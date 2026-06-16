import Foundation

/// The verdict-cache surface `StowerDebtBoardProvider` depends on.
///
/// Abstracts `StowerReplyVerdictCache` to the two hot-path operations the
/// provider actually uses, so the provider can be exercised against a
/// fault-injecting double (a locked or corrupt store) without a real database.
/// Pruning stays on the concrete cache. Disposable (M9): a throwing call resolves
/// to an unjudged row (excluded from the board) and a retried write, never a
/// block. The conforming cache is the trust boundary — `upsert` rejects malformed
/// payloads and `existing` resolves an unknown source token to a miss.
internal protocol StowerReplyVerdictCaching: Sendable {
    /// Returns the cached verdict only when version, guid, AND input hash match.
    func existing(
        judgeVersion: String,
        guid: String,
        inputHash: String
    ) async throws -> StowerReplyExpectation?

    /// Inserts or replaces the verdict for `(judgeVersion, guid)`.
    func upsert(
        judgeVersion: String,
        guid: String,
        inputHash: String,
        verdict: StowerReplyExpectation
    ) async throws
}

extension StowerReplyVerdictCache: StowerReplyVerdictCaching {}
