import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerGhostedPolicy")
internal struct StowerGhostedPolicyTests {
    @Test("gates on expectsReply AND confidence: only the confident ask survives (M1)")
    internal func gateOnExpectsReplyAndConfidence() {
        let input = [
            judged(state(chatID: "ask"), expectsReply: true, confidence: 0.95),
            judged(state(chatID: "confident-non-ask"), expectsReply: false, confidence: 0.95),
            judged(state(chatID: "low-conf-ask"), expectsReply: true, confidence: 0.4)
        ]
        // Default threshold 0.5: the confident non-ask gates out on expectsReply,
        // the low-confidence ask gates out on the threshold; only the ask remains.
        #expect(ghosted(for: input).map(\.chatID) == ["ask"])
    }

    @Test("a counterpart tapback on your last message clears Ghosted (T1)")
    internal func counterpartTapbackClears() {
        let reacted = judged(
            state(chatID: "acked", counterpartReactedToLastMessage: true),
            expectsReply: true,
            confidence: 0.95
        )
        #expect(ghosted(for: [reacted]).isEmpty)
    }

    @Test("a thread where the counterpart acted last is never a ghost")
    internal func counterpartLastExcluded() {
        let input = [judged(state(chatID: "theirs", lastActor: .counterpart), confidence: 0.95)]
        #expect(ghosted(for: input).isEmpty)
    }

    @Test("a non-text last act never expects a reply, so it never ghosts")
    internal func nonTextNeverGhosts() {
        let input = [
            judged(
                state(chatID: "photo", lastMessageKind: .attachment, lastMessageText: nil),
                expectsReply: false,
                confidence: 0
            )
        ]
        #expect(ghosted(for: input).isEmpty)
    }

    @Test("the mutuality gate and threshold apply, ranked most-recent first")
    internal func mutualityThresholdAndRanking() {
        let input = [
            judged(state(chatID: "lone", recentExchangeCount: 0), confidence: 0.95),
            judged(state(chatID: "older", daysAgo: 30), confidence: 0.95),
            judged(state(chatID: "newer", daysAgo: 16), confidence: 0.95),
            judged(state(chatID: "fresh", daysAgo: 2), confidence: 0.95)
        ]
        // `lone` fails mutuality; `fresh` is below the 14-day threshold.
        #expect(ghosted(for: input).map(\.chatID) == ["newer", "older"])
    }

    @Test("a custom threshold admits a graded-confident ask the default excludes")
    internal func thresholdIsALiveKnob() {
        let input = [judged(state(chatID: "bare-q"), expectsReply: true, confidence: 0.4)]
        #expect(ghosted(for: input).isEmpty)
        #expect(ghosted(for: input, ghostGateThreshold: 0.3).map(\.chatID) == ["bare-q"])
    }

    @Test("a negative or non-finite threshold fails closed, never bypassing the gate")
    internal func invalidThresholdFailsClosed() {
        // A confident non-ask would leak in if a negative threshold collapsed the
        // confidence gate to always-true; it must instead yield an empty board.
        let input = [judged(state(chatID: "non-ask"), expectsReply: false, confidence: 0.95)]
        #expect(ghosted(for: input, ghostGateThreshold: -1).isEmpty)
        #expect(ghosted(for: input, ghostGateThreshold: .nan).isEmpty)
        #expect(ghosted(for: input, ghostGateThreshold: -.infinity).isEmpty)
        // And a real ask is dropped too — fail closed beats inverting the gate.
        let ask = [judged(state(chatID: "ask"), expectsReply: true, confidence: 0.95)]
        #expect(ghosted(for: ask, ghostGateThreshold: -0.5).isEmpty)
    }
}

// MARK: - Synthetic builders

extension StowerGhostedPolicyTests {
    private var now: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }

    fileprivate func ghosted(
        for judged: [StowerJudgedConversation],
        unansweredForDays: Int = 14,
        minimumReciprocity: Int = 1,
        ghostGateThreshold: Double = 0.5
    ) -> [StowerDebtItem] {
        StowerGhostedPolicy.ghosted(
            from: judged,
            unansweredForDays: unansweredForDays,
            minimumReciprocity: minimumReciprocity,
            ghostGateThreshold: ghostGateThreshold,
            now: now
        )
    }

    fileprivate func judged(
        _ state: StowerConversationState,
        expectsReply: Bool = true,
        confidence: Double = 1.0
    ) -> StowerJudgedConversation {
        StowerJudgedConversation(
            state: state,
            verdict: StowerReplyExpectation(
                expectsReply: expectsReply,
                replyExpectationConfidence: confidence,
                verdictSource: .languageModel
            )
        )
    }

    fileprivate func state(
        chatID: String,
        isOneToOne: Bool = true,
        lastActor: StowerConversationLastActor = .user,
        recentExchangeCount: Int = 2,
        counterpartReactedToLastMessage: Bool = false,
        lastMessageKind: StowerConversationLastMessageKind = .text,
        lastMessageText: String? = "are we still on?",
        daysAgo: Double = 30
    ) -> StowerConversationState {
        StowerConversationState(
            chatID: chatID,
            chatTitle: chatID,
            counterpart: chatID,
            counterpartHandle: "+1555\(chatID)",
            isOneToOne: isOneToOne,
            lastActor: lastActor,
            lastInboundAt: now.addingTimeInterval(-(daysAgo + 1) * 86_400),
            lastOutboundAt: now.addingTimeInterval(-daysAgo * 86_400),
            lastMessageKind: lastMessageKind,
            lastMessageText: lastMessageText,
            lastMessageTimestamp: now.addingTimeInterval(-daysAgo * 86_400),
            recentExchangeCount: recentExchangeCount,
            userReactedToLastMessage: false,
            counterpartReactedToLastMessage: counterpartReactedToLastMessage,
            deepLink: nil
        )
    }
}
