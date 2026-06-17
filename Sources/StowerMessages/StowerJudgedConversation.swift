import Foundation

/// A conversation's facts paired with its trusted reply-expectation verdict.
///
/// The provider pairs each conversation with its cached language-model verdict
/// (unjudged conversations are excluded upstream) and hands the pairs to both
/// policies, so neither re-reads facts nor re-runs a judge.
internal struct StowerJudgedConversation: Sendable, Equatable {
    /// The neutral per-conversation facts.
    internal let state: StowerConversationState

    /// The reply-expectation verdict for the conversation's last act.
    internal let verdict: StowerReplyExpectation
}
