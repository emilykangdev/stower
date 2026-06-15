import Foundation

/// Which judge produced a reply-expectation verdict.
///
/// The string raw values double as the verdict cache's stored source token, so
/// renaming a case is a cache-schema change. Both Apple's on-device
/// FoundationModels judge and a future MLX judge report `.languageModel`; only
/// the deterministic fallback reports `.heuristic`. Trust
/// `replyExpectationConfidence` only when this is `.languageModel`.
public enum StowerReplyJudgeSource: String, Sendable, Equatable {
    /// The deterministic `?`-plus-ask-cue fallback produced the verdict.
    case heuristic

    /// An on-device language model (FoundationModels or a future MLX) produced it.
    case languageModel
}
