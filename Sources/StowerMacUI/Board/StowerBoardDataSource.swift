import Foundation

/// The app-owned board boundary the SwiftUI layer depends on.
///
/// Parallel to `StowerStartupProviding`: it speaks only app-owned types, so the
/// board view-models never import the engine. The production conformer is the
/// engine-coupled `StowerLiveBoardDataSource`; tests inject spies.
///
/// Uses **untyped** `throws`, matching `StowerStartupProviding`. The adapter
/// catches `StowerMessagesError` and throws the app-owned `StowerStartupFailure`,
/// and lets `CancellationError` propagate unchanged — a load cancelled because a
/// newer one replaced it (or its view was dismissed) must never route to a failure
/// screen, which a `throws(StowerStartupFailure)` seam could not express.
internal protocol StowerBoardDataSource: Sendable {
    /// Loads the two-lens board at structural speed (cached verdicts only).
    ///
    /// - Parameters:
    ///   - config: The debt-board knobs (the visible day preset's threshold).
    ///   - now: The reference time the board is computed against.
    /// - Returns: The pre-ranked board; possibly empty on a cold cache.
    /// - Throws: A `StowerStartupFailure` for an FDA/source/model error, or
    ///   `CancellationError` when superseded.
    func loadBoard(config: StowerStartupDebtConfig, now: Date) async throws -> StowerBoardModel

    /// Loads a single conversation's recent thread, oldest-first.
    ///
    /// - Parameters:
    ///   - chatID: The conversation to read.
    ///   - limit: The newest-N messages to return.
    /// - Returns: Thread lines in render order (oldest-first), never re-sorted.
    /// - Throws: A `StowerStartupFailure` for an FDA/source error, or
    ///   `CancellationError` when superseded.
    func thread(chatID: String, limit: Int) async throws -> [StowerThreadLine]

    /// Runs the background language-model pass and reports a distilled outcome.
    ///
    /// - Parameters:
    ///   - config: The debt-board knobs for the pass.
    ///   - now: The reference time for the pass.
    /// - Returns: The app-owned outcome the view-model acts on.
    /// - Throws: A `StowerStartupFailure` for a mid-session FDA/source/model error,
    ///   or `CancellationError` when superseded.
    func refreshJudgments(
        config: StowerStartupDebtConfig,
        now: Date
    ) async throws -> StowerBoardRefreshOutcome
}
