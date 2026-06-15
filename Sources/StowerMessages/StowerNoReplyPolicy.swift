import Foundation

/// The Neglected lens: the counterpart acted last and you haven't replied.
///
/// Pure and stateless. RANKS, never filters on the verdict — they messaged you
/// and you owe at least an acknowledgment regardless, so every qualifying row
/// stays; `expectsReply` only floats real questions above the chit-chat. The
/// structural gate is unchanged from the original no-reply pass (1:1,
/// mutuality, counterpart-last, not tapped back, unanswered long enough).
internal enum StowerNoReplyPolicy {
    /// Selects and ranks the conversations you owe a reply to.
    ///
    /// Ranks two-tier: `expectsReply` first, then most-recently-unanswered, with
    /// deterministic ties (older timestamp loses, then `chatID`). A negative
    /// threshold or floor fails closed (no rows) rather than inverting the gate.
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
                    $0.state,
                    minimumReciprocity: minimumReciprocity,
                    threshold: threshold,
                    now: now
                )
            }
            .sorted(by: neglectedRank)
            .map { StowerDebtItem(state: $0.state, verdict: $0.verdict) }
    }

    private static func qualifies(
        _ state: StowerConversationState,
        minimumReciprocity: Int,
        threshold: Double,
        now: Date
    ) -> Bool {
        state.isOneToOne
            && state.recentExchangeCount >= minimumReciprocity
            && state.lastActor == .counterpart
            && !state.userReactedToLastMessage
            && now.timeIntervalSince(state.lastMessageTimestamp) >= threshold
    }

    private static func neglectedRank(
        _ lhs: StowerJudgedConversation,
        _ rhs: StowerJudgedConversation
    ) -> Bool {
        if lhs.verdict.expectsReply != rhs.verdict.expectsReply {
            return lhs.verdict.expectsReply
        }
        return rank(lhs.state, rhs.state)
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
