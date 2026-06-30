import Foundation

/// The Neglected lens: the counterpart sent a statement worth responding to and
/// you have neither replied nor reacted.
///
/// Pure and stateless, and judged-only: a row qualifies only when the model
/// judged the counterpart's last act as one the user should respond to
/// (`expectsReply`). Surfacing unjudged or "okay-to-ignore" rows would train
/// compulsive replying, so the gate is the product's value. The structural gate
/// is the original no-reply pass (1:1, mutuality, counterpart-last, not tapped
/// back, unanswered long enough); unlike Ghosted, Neglected gates on the
/// should-respond boolean only, not a confidence threshold.
internal enum StowerNoReplyPolicy {
    /// Selects and ranks the conversations you owe a reply to.
    ///
    /// Ranked by most-recently-unanswered with deterministic ties (older
    /// timestamp loses, then `chatID`). A negative threshold or floor fails closed
    /// (no rows) rather than inverting the gate.
    internal static func neglected(
        from judged: [StowerJudgedConversation],
        unansweredForDays: Int,
        minimumReciprocity: Int,
        now: Date
    ) -> [StowerDebtItem] {
        guard unansweredForDays >= 0, minimumReciprocity >= 0 else {
            return []
        }
        let threshold = Double(unansweredForDays) * 86_400
        return
            judged
            .filter {
                qualifies(
                    $0,
                    minimumReciprocity: minimumReciprocity,
                    threshold: threshold,
                    now: now
                )
            }
            .sorted { rank($0.state, $1.state) }
            .map {
                StowerDebtItem(
                    state: $0.state,
                    replyExpectationConfidence: $0.verdict.replyExpectationConfidence,
                    lastMessageGUID: $0.lastMessageGUID
                )
            }
    }

    private static func qualifies(
        _ judged: StowerJudgedConversation,
        minimumReciprocity: Int,
        threshold: Double,
        now: Date
    ) -> Bool {
        let state = judged.state
        return state.isOneToOne
            && state.recentExchangeCount >= minimumReciprocity
            && state.lastActor == .counterpart
            && !state.userReactedToLastMessage
            && now.timeIntervalSince(state.lastMessageTimestamp) >= threshold
            && judged.verdict.expectsReply
    }

    /// The total recency order shared with `StowerGhostedPolicy` (M-E2): newer
    /// unanswered first, ties broken by `chatID` for a stable sort.
    internal static func rank(
        _ lhs: StowerConversationState,
        _ rhs: StowerConversationState
    ) -> Bool {
        if lhs.lastMessageTimestamp != rhs.lastMessageTimestamp {
            return lhs.lastMessageTimestamp > rhs.lastMessageTimestamp
        }
        return lhs.chatID < rhs.chatID
    }
}
