import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerNoReplyPolicy")
internal struct StowerNoReplyPolicyTests {
    @Test("a recent two-way thread the user owes becomes a candidate")
    internal func qualifyingThreadSurfaces() {
        let result = candidates(for: states(state(chatID: "a")))
        #expect(result.map(\.chatID) == ["a"])
    }

    @Test("a group / non-1:1 state never appears")
    internal func groupExcluded() {
        let result = candidates(for: states(state(chatID: "g", isOneToOne: false)))
        #expect(result.isEmpty)
    }

    @Test("the mutuality gate excludes below minimumReciprocity, includes at or above")
    internal func mutualityGate() {
        let pair = states(
            state(chatID: "lone", recentExchangeCount: 0),
            state(chatID: "mutual", recentExchangeCount: 2)
        )
        #expect(candidates(for: pair).map(\.chatID) == ["mutual"])
        #expect(candidates(for: pair, minimumReciprocity: 2).map(\.chatID) == ["mutual"])
        let one = states(state(chatID: "one", recentExchangeCount: 1))
        #expect(candidates(for: one, minimumReciprocity: 2).isEmpty)
    }

    @Test("a thread whose true last act is the user's is excluded")
    internal func userLastActExcluded() {
        #expect(candidates(for: states(state(chatID: "u", lastActor: .user))).isEmpty)
    }

    @Test("a tapback-cleared thread is excluded")
    internal func reactedExcluded() {
        #expect(candidates(for: states(state(chatID: "x", userReactedToLastMessage: true))).isEmpty)
    }

    @Test("a non-text last act is surfaced with its kind and nil text, not suppressed")
    internal func nonTextSurfaced() throws {
        let input = states(
            state(chatID: "photo", lastMessageKind: .attachment, lastMessageText: nil)
        )
        let candidate = try #require(candidates(for: input).first)
        #expect(candidate.lastMessageKind == .attachment)
        #expect(candidate.lastMessageText == nil)
    }

    @Test("threshold honored exactly: age below is excluded, at or above is included")
    internal func thresholdBoundary() {
        let input = states(state(chatID: "below", daysAgo: 13), state(chatID: "at", daysAgo: 14))
        #expect(candidates(for: input, unansweredForDays: 14).map(\.chatID) == ["at"])
    }

    @Test("candidates rank most-recently-unanswered first, ties broken by chatID")
    internal func rankingDeterministic() {
        let input = states(
            state(chatID: "older", daysAgo: 30),
            state(chatID: "tie-b", daysAgo: 20),
            state(chatID: "tie-a", daysAgo: 20),
            state(chatID: "newer", daysAgo: 16)
        )
        #expect(candidates(for: input).map(\.chatID) == ["newer", "tie-a", "tie-b", "older"])
    }
}

// MARK: - Synthetic builders

extension StowerNoReplyPolicyTests {
    private var now: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }

    fileprivate func states(_ values: StowerConversationState...) -> [StowerConversationState] {
        values
    }

    fileprivate func candidates(
        for states: [StowerConversationState],
        unansweredForDays: Int = 14,
        minimumReciprocity: Int = 1
    ) -> [StowerNoReplyCandidate] {
        StowerNoReplyPolicy.candidates(
            from: states,
            unansweredForDays: unansweredForDays,
            minimumReciprocity: minimumReciprocity,
            now: now
        )
    }

    fileprivate func state(
        chatID: String,
        isOneToOne: Bool = true,
        lastActor: StowerConversationLastActor = .counterpart,
        recentExchangeCount: Int = 2,
        userReactedToLastMessage: Bool = false,
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
            deepLink: nil
        )
    }
}
