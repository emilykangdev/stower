import Foundation

/// A conversation's facts paired with its reply-expectation verdict.
///
/// The provider judges each conversation (cached language-model verdict or
/// inline heuristic) and hands the pairs to both policies, so neither re-reads
/// facts nor re-runs a judge.
internal struct StowerJudgedConversation: Sendable, Equatable {
    /// The neutral per-conversation facts.
    internal let state: StowerConversationState

    /// The reply-expectation verdict for the conversation's last act.
    internal let verdict: StowerReplyExpectation
}
