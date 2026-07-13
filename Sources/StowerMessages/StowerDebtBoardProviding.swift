import Foundation

/// The single seam the StowerMac app depends on for the relationship-debt board.
///
/// A long-lived actor, stateless across calls except for its disposable verdict
/// cache. The app calls `modelAvailability()` at startup to route before any
/// board work; `loadDebtBoard` returns at structural speed and never runs a
/// model; `refreshJudgments` is the background pass that backfills language-model
/// verdicts for the next load and reports completion progress plus what changed.
public protocol StowerDebtBoardProviding: Sendable {
    /// Whether the on-device language model can serve verdicts right now.
    ///
    /// Cheap and standalone — the app calls it at startup, BEFORE any board work,
    /// to route to the board, an onboarding screen, or an unsupported screen.
    func modelAvailability() async -> StowerModelAvailability

    /// Builds the two-lens, judged-only board from fresh facts plus trusted
    /// cached verdicts.
    ///
    /// Never blocks on the model: it serves only conversations a trusted verdict
    /// is already cached for, and excludes the rest (cold start returns empty
    /// lists). Throws `languageModelUnavailable(reason)` before opening the
    /// database when the model is unavailable, and a typed `StowerMessagesError`
    /// when the source can't be read (e.g. missing Messages access).
    func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard

    /// Returns the newest `limit` messages of one chat, ordered oldest-first for
    /// display, for a tap-through thread view.
    ///
    /// Two-part contract: the selection is the newest `limit` eligible messages,
    /// and they are returned **oldest-first** so the view renders top-to-bottom
    /// without re-sorting. The app relies on this order and cannot re-derive it
    /// (`StowerThreadMessage` carries no sequence to sort by).
    func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage]

    /// Runs the language model in the background, backfills the cache, and reports
    /// completion progress (`judged`/`failed`/`total`) plus the conversations
    /// whose verdict changed.
    ///
    /// Returns `nil` only when coalesced — a pass is already running; the app
    /// keeps its current state and the in-flight pass returns the real summary.
    /// Throws `languageModelUnavailable(reason)` when the model is unavailable
    /// (including a mid-session change), symmetric with `loadDebtBoard`.
    func refreshJudgments(config: StowerDebtConfig, now: Date) async throws -> StowerRefreshSummary?
}
