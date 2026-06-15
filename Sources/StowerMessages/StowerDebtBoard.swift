import Foundation

/// The two-lens relationship-debt board the app renders.
///
/// Both lenses arrive pre-ordered; the app re-sorts neither. `neglected` (the
/// counterpart acted last) is RANKED and never filtered — you owe at least an
/// acknowledgment regardless, and `expectsReply` only floats real questions
/// above the chit-chat. `ghosted` (you acted last) is GATED on
/// `expectsReply && replyExpectationConfidence >= ghostGateThreshold` and then
/// ranked by recency, because "you sent last, no reply" is mostly benign and
/// would flood without a gate.
public struct StowerDebtBoard: Sendable, Equatable {
    /// Conversations the counterpart left with you, ranked, never filtered.
    public let neglected: [StowerDebtItem]

    /// Conversations you left on a real ask with no reply, gated then ranked.
    public let ghosted: [StowerDebtItem]

    /// Creates a debt board from its two pre-ordered lenses.
    public init(neglected: [StowerDebtItem], ghosted: [StowerDebtItem]) {
        self.neglected = neglected
        self.ghosted = ghosted
    }
}
