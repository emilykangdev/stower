import Foundation

@testable import StowerMessages

/// A counting, scriptable `StowerReplyExpectationJudge` for provider tests.
///
/// Records how many times it was asked to judge so a test can assert the load
/// path never calls a model. Optionally throws to model an on-device failure.
internal final class StowerSpyReplyJudge: StowerReplyExpectationJudge, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0
    private let shouldThrow: Bool
    private let verdictFor: @Sendable (String?) -> StowerReplyExpectation
    internal let judgeVersion: String

    internal init(
        judgeVersion: String = "spy-v1",
        shouldThrow: Bool = false,
        verdict: @escaping @Sendable (String?) -> StowerReplyExpectation = { _ in
            StowerReplyExpectation(
                expectsReply: true,
                replyExpectationConfidence: 0.9,
                verdictSource: .languageModel
            )
        }
    ) {
        self.judgeVersion = judgeVersion
        self.shouldThrow = shouldThrow
        verdictFor = verdict
    }

    /// How many times `judge` has been invoked.
    internal var callCount: Int {
        lock.withLock { invocations }
    }

    internal func judge(
        messageText: String?,
        context: [String]
    ) async throws -> StowerReplyExpectation {
        lock.withLock { invocations += 1 }
        if shouldThrow {
            throw StowerSpyJudgeError.forced
        }
        return verdictFor(messageText)
    }
}

internal enum StowerSpyJudgeError: Error {
    case forced
}

/// A synthetic facts source so the provider runs without a real `chat.db`.
internal struct StowerStubFactsReader: StowerConversationFactsReading {
    internal let records: [StowerConversationStateRecord]
    internal var threads: [String: [StowerThreadMessage]] = [:]

    internal func conversationStateRecords(
        windowDays: Int,
        now: Date
    ) async throws -> [StowerConversationStateRecord] {
        records
    }

    internal func threadMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage] {
        threads[chatID] ?? []
    }
}

/// Builds a conversation-state record for provider tests.
internal func stowerTestRecord(
    chatID: String,
    guid: String,
    lastActor: StowerConversationLastActor = .counterpart,
    lastMessageText: String? = "hi",
    lastMessageKind: StowerConversationLastMessageKind = .text,
    recentExchangeCount: Int = 2,
    counterpartReactedToLastMessage: Bool = false,
    daysAgo: Double = 30,
    now: Date
) -> StowerConversationStateRecord {
    let timestamp = now.addingTimeInterval(-daysAgo * 86_400)
    let state = StowerConversationState(
        chatID: chatID,
        chatTitle: chatID,
        counterpart: chatID,
        counterpartHandle: "+1555\(chatID)",
        isOneToOne: true,
        lastActor: lastActor,
        lastInboundAt: timestamp,
        lastOutboundAt: timestamp,
        lastMessageKind: lastMessageKind,
        lastMessageText: lastMessageText,
        lastMessageTimestamp: timestamp,
        recentExchangeCount: recentExchangeCount,
        userReactedToLastMessage: false,
        counterpartReactedToLastMessage: counterpartReactedToLastMessage,
        deepLink: nil
    )
    return StowerConversationStateRecord(state: state, lastMessageGUID: guid)
}
