import Foundation

/// The two-lens relationship-debt board the app renders.
///
/// Both lenses arrive pre-ordered and judged-only; the app re-sorts neither. Each
/// gates on the model's should-respond verdict, differing only by direction:
/// `neglected` (the counterpart acted last) gates on the should-respond boolean
/// and ranks by recency; `ghosted` (you acted last) additionally gates on
/// `replyExpectationConfidence >= ghostGateThreshold` because "you sent last, no
/// reply" is noisier and would flood without it. A conversation the model has not
/// judged appears in neither list.
public struct StowerDebtBoard: Sendable, Equatable {
    /// Conversations the counterpart left with you, judged then ranked.
    public let neglected: [StowerDebtItem]

    /// Conversations you left on a statement worth a reply, judged then ranked.
    public let ghosted: [StowerDebtItem]

    /// Creates a debt board from its two pre-ordered lenses.
    public init(neglected: [StowerDebtItem], ghosted: [StowerDebtItem]) {
        self.neglected = neglected
        self.ghosted = ghosted
    }
}
