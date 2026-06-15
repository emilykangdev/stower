import Foundation

/// A judge's verdict on whether one message expects a reply.
///
/// Produced by a `StowerReplyExpectationJudge` over a single message's text.
/// `replyExpectationConfidence` is a soft `0...1` score: the language model
/// emits it directly and the heuristic grades it, so `ghostGateThreshold` is a
/// live knob on either path. Trust the score only when `verdictSource` is
/// `.languageModel` — the heuristic's grades are coarse cue heuristics.
public struct StowerReplyExpectation: Sendable, Equatable {
    /// Whether the message reads as expecting a reply (a question or an ask).
    public let expectsReply: Bool

    /// Soft `0...1` confidence in `expectsReply`; trust only for `.languageModel`.
    public let replyExpectationConfidence: Double

    /// Which judge produced this verdict.
    public let verdictSource: StowerReplyJudgeSource

    /// A short, optional rationale; never persisted (no long-form content stored).
    public let reason: String?

    /// Creates a reply-expectation verdict.
    public init(
        expectsReply: Bool,
        replyExpectationConfidence: Double,
        verdictSource: StowerReplyJudgeSource,
        reason: String? = nil
    ) {
        self.expectsReply = expectsReply
        self.replyExpectationConfidence = replyExpectationConfidence
        self.verdictSource = verdictSource
        self.reason = reason
    }
}
