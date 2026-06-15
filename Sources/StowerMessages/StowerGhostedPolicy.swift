import Foundation

/// The Ghosted lens: you acted last on a real ask and got no reply.
///
/// Pure and stateless. Unlike Neglected, this GATES list membership — "you sent
/// last, no reply" is mostly benign (most chats just end on "👍 sounds good"),
/// so without a gate the list floods with false ghosts and stops being trusted.
/// A row qualifies only when you acted last, the counterpart did not even tap
/// back (T1), the thread is a real two-way relationship, it has been unanswered
/// long enough, and the judge says the message expects a reply with confidence
/// at or above the threshold (M1 — confidence alone is not enough; a confident
/// non-ask must gate out). Ranked by recency, reusing `StowerNoReplyPolicy.rank`.
internal enum StowerGhostedPolicy {
    /// Selects and ranks the conversations where you ghosted nobody but were
    /// ghosted — your real ask left hanging.
    ///
    /// A negative threshold or floor fails closed (no rows) rather than
    /// inverting a gate.
    internal static func ghosted(
        from judged: [StowerJudgedConversation],
        unansweredForDays: Int,
        minimumReciprocity: Int,
        ghostGateThreshold: Double,
        now: Date
    ) -> [StowerDebtItem] {
        // A negative threshold would make `confidence >= threshold` always true,
        // collapsing the M1 confidence gate so confident non-asks leak in; a
        // non-finite one corrupts the comparison. Fail closed rather than invert
        // the gate. (A threshold above 1 just yields an empty board — also safe.)
        guard unansweredForDays >= 0, minimumReciprocity >= 0,
            ghostGateThreshold.isFinite, ghostGateThreshold >= 0
        else {
            return []
        }
        let threshold = Double(unansweredForDays) * 86_400
        return
            judged
            .filter {
                gate(
                    $0,
                    minimumReciprocity: minimumReciprocity,
                    threshold: threshold,
                    ghostGateThreshold: ghostGateThreshold,
                    now: now
                )
            }
            .sorted { StowerNoReplyPolicy.rank($0.state, $1.state) }
            .map { StowerDebtItem(state: $0.state, verdict: $0.verdict) }
    }

    private static func gate(
        _ judged: StowerJudgedConversation,
        minimumReciprocity: Int,
        threshold: Double,
        ghostGateThreshold: Double,
        now: Date
    ) -> Bool {
        let state = judged.state
        return state.isOneToOne
            && state.recentExchangeCount >= minimumReciprocity
            && state.lastActor == .user
            && !state.counterpartReactedToLastMessage
            && now.timeIntervalSince(state.lastMessageTimestamp) >= threshold
            && judged.verdict.expectsReply
            && judged.verdict.replyExpectationConfidence >= ghostGateThreshold
    }
}
