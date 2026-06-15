import Foundation

/// How the debt board should pick a reply-expectation judge for a call.
///
/// `loadDebtBoard` never runs a model regardless of this mode — it reads cached
/// language-model verdicts plus the inline heuristic. The mode governs which
/// judge `refreshJudgments` backfills with, and whether a cached language-model
/// verdict is preferred over the heuristic on load.
public enum StowerReplyJudgeMode: Sendable, Equatable {
    /// Always use the deterministic heuristic; `refreshJudgments` is a no-op.
    case heuristic

    /// Prefer the language model when available, else the heuristic.
    case languageModel

    /// Language model when the system supports it, otherwise the heuristic.
    case automatic
}
