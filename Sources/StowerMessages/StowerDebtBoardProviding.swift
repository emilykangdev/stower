import Foundation

/// The single seam the StowerMac app depends on for the relationship-debt board.
///
/// A long-lived actor, stateless across calls except for its disposable verdict
/// cache. `loadDebtBoard` returns at structural speed and never runs a model;
/// `refreshJudgments` is the background pass that backfills language-model
/// verdicts for the next load and reports what changed.
public protocol StowerDebtBoardProviding: Sendable {
    /// Builds the two-lens board from fresh facts plus cached/heuristic verdicts.
    ///
    /// Never blocks on the model: a cached language-model verdict is used only if
    /// present, otherwise the inline heuristic. Throws a typed
    /// `StowerMessagesError` when the source can't be read (e.g. missing Full
    /// Disk Access).
    func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard

    /// Returns the newest messages of one chat for a tap-through thread view.
    func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage]

    /// Runs the language model in the background, backfills the cache, and
    /// reports the conversations whose verdict changed.
    ///
    /// A no-op (empty summary) under `.heuristic`, when the model is unavailable,
    /// or when the cache is absent.
    func refreshJudgments(config: StowerDebtConfig, now: Date) async -> StowerRefreshSummary
}
