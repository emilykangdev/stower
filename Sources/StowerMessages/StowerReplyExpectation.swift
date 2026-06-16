import Foundation

/// A judge's verdict on whether one message should be responded to.
///
/// Produced by a `StowerReplyExpectationJudge` over a single message's text.
/// `replyExpectationConfidence` is a soft `0...1` score the on-device language
/// model emits directly, so `ghostGateThreshold` is a live knob over it. Trust
/// the score only when `verdictSource.isTrustedVerdictSource`. Internal: no public
/// API returns it — the app consumes `StowerDebtItem`, never this verdict.
internal struct StowerReplyExpectation: Sendable, Equatable {
    /// Whether the recipient should reasonably respond to the message.
    internal let expectsReply: Bool

    /// Soft `0...1` confidence in `expectsReply`; trust only for a trusted source.
    internal let replyExpectationConfidence: Double

    /// Which judge produced this verdict.
    internal let verdictSource: StowerReplyJudgeSource

    /// A short, optional rationale; never persisted (no long-form content stored).
    internal let reason: String?

    /// Creates a reply-expectation verdict.
    internal init(
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
