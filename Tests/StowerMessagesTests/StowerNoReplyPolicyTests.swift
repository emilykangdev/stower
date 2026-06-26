import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerNoReplyPolicy")
internal struct StowerNoReplyPolicyTests {
    @Test("a recent two-way thread the model says to respond to becomes a row")
    internal func qualifyingThreadSurfaces() {
        let result = neglected(for: [judged(state(chatID: "a"))])
        #expect(result.map(\.chatID) == ["a"])
    }

    @Test("the last act's GUID propagates from the judged conversation onto the row (A2)")
    internal func lastMessageGUIDReachesItem() {
        let result = neglected(for: [judged(state(chatID: "a"))])
        #expect(result.first?.lastMessageGUID == "guid-a")
    }

    @Test("a group / non-1:1 state never appears")
    internal func groupExcluded() {
        let result = neglected(for: [judged(state(chatID: "g", isOneToOne: false))])
        #expect(result.isEmpty)
    }

    @Test("the mutuality gate excludes below minimumReciprocity, includes at or above")
    internal func mutualityGate() {
        let pair = [
            judged(state(chatID: "lone", recentExchangeCount: 0)),
            judged(state(chatID: "mutual", recentExchangeCount: 2))
        ]
        #expect(neglected(for: pair).map(\.chatID) == ["mutual"])
        #expect(neglected(for: pair, minimumReciprocity: 2).map(\.chatID) == ["mutual"])
        let one = [judged(state(chatID: "one", recentExchangeCount: 1))]
        #expect(neglected(for: one, minimumReciprocity: 2).isEmpty)
    }

    @Test("a thread whose true last act is the user's is excluded")
    internal func userLastActExcluded() {
        #expect(neglected(for: [judged(state(chatID: "u", lastActor: .user))]).isEmpty)
    }

    @Test("a tapback-cleared thread is excluded")
    internal func reactedExcluded() {
        let cleared = judged(state(chatID: "x", userReactedToLastMessage: true))
        #expect(neglected(for: [cleared]).isEmpty)
    }

    @Test("a judged not-should-respond thread is gated out, not just ranked lower")
    internal func notShouldRespondGatedOut() {
        let input = [
            judged(state(chatID: "ask"), expectsReply: true),
            judged(state(chatID: "chitchat"), expectsReply: false)
        ]
        // The gate is the product's value: only should-respond statements surface.
        #expect(neglected(for: input).map(\.chatID) == ["ask"])
    }

    @Test("a should-respond non-text last act surfaces with its kind and nil text")
    internal func nonTextShouldRespondSurfaced() throws {
        let input = [
            judged(
                state(chatID: "photo", lastMessageKind: .attachment, lastMessageText: nil),
                expectsReply: true
            )
        ]
        let row = try #require(neglected(for: input).first)
        #expect(row.lastMessageKind == .attachment)
        #expect(row.lastMessageText == nil)
    }

    @Test("threshold honored exactly: age below is excluded, at or above is included")
    internal func thresholdBoundary() {
        let input = [
            judged(state(chatID: "below", daysAgo: 13)),
            judged(state(chatID: "at", daysAgo: 14))
        ]
        #expect(neglected(for: input, unansweredForDays: 14).map(\.chatID) == ["at"])
    }

    @Test("negative arguments fail closed (no rows), never inverting the gate")
    internal func negativeArgumentsFailClosed() {
        let qualifying = [judged(state(chatID: "a"))]
        #expect(neglected(for: qualifying, unansweredForDays: -1).isEmpty)
        #expect(neglected(for: qualifying, unansweredForDays: 14, minimumReciprocity: -1).isEmpty)
    }

    @Test("ranks most-recently-unanswered first, ties broken by chatID")
    internal func ranksByRecencyThenChatID() {
        let input = [
            judged(state(chatID: "older", daysAgo: 30)),
            judged(state(chatID: "newer", daysAgo: 16)),
            judged(state(chatID: "tie-b", daysAgo: 20)),
            judged(state(chatID: "tie-a", daysAgo: 20))
        ]
        #expect(neglected(for: input).map(\.chatID) == ["newer", "tie-a", "tie-b", "older"])
    }
}

// MARK: - Synthetic builders

extension StowerNoReplyPolicyTests {
    private var now: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }

    fileprivate func neglected(
        for judged: [StowerJudgedConversation],
        unansweredForDays: Int = 14,
        minimumReciprocity: Int = 1
    ) -> [StowerDebtItem] {
        StowerNoReplyPolicy.neglected(
            from: judged,
            unansweredForDays: unansweredForDays,
            minimumReciprocity: minimumReciprocity,
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
            ),
            lastMessageGUID: "guid-\(state.chatID)"
        )
    }

    fileprivate func state(
        chatID: String,
        isOneToOne: Bool = true,
        lastActor: StowerConversationLastActor = .counterpart,
        recentExchangeCount: Int = 2,
        userReactedToLastMessage: Bool = false,
        counterpartReactedToLastMessage: Bool = false,
        lastMessageKind: StowerConversationLastMessageKind = .text,
        lastMessageText: String? = "hi",
        daysAgo: Double = 30
    ) -> StowerConversationState {
        StowerConversationState(
            chatID: chatID,
            chatTitle: chatID,
            counterpart: chatID,
            counterpartHandle: "+1555\(chatID)",
            isOneToOne: isOneToOne,
            lastActor: lastActor,
            lastInboundAt: now.addingTimeInterval(-daysAgo * 86_400),
            lastOutboundAt: now.addingTimeInterval(-(daysAgo + 1) * 86_400),
            lastMessageKind: lastMessageKind,
            lastMessageText: lastMessageText,
            lastMessageTimestamp: now.addingTimeInterval(-daysAgo * 86_400),
            recentExchangeCount: recentExchangeCount,
            userReactedToLastMessage: userReactedToLastMessage,
            counterpartReactedToLastMessage: counterpartReactedToLastMessage,
            deepLink: nil
        )
    }
}
