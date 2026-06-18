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
    private let version: String

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
        version = judgeVersion
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

    /// The spy's fixed version so tests can pin a known cache key.
    internal func judgeVersion() -> String { version }
}

internal enum StowerSpyJudgeError: Error {
    case forced
}

/// A judge that hangs cooperatively until cancelled, for timeout/cancel tests.
///
/// Its `judge` awaits an effectively unbounded `Task.sleep` that throws on
/// cancellation, so the per-record timeout (or a parent cancel) deterministically
/// resolves the call instead of hanging CI. Counts invocations like the spy.
internal final class StowerHangingReplyJudge: StowerReplyExpectationJudge, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0

    /// How many times `judge` has been invoked.
    internal var callCount: Int {
        lock.withLock { invocations }
    }

    internal func judge(
        messageText: String?,
        context: [String]
    ) async throws -> StowerReplyExpectation {
        lock.withLock { invocations += 1 }
        try await Task.sleep(for: .seconds(3_600))
        return StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: 0.9,
            verdictSource: .languageModel
        )
    }

    internal func judgeVersion() -> String { "hang-v1" }
}

/// A verdict cache double that fails on demand, modeling a locked/corrupt store.
///
/// Lets a test prove the disposable-cache invariants (M9): a read fault excludes
/// a row without blocking, and a write fault is counted failed and never reported
/// as a persisted change.
internal struct StowerFaultyVerdictCache: StowerReplyVerdictCaching {
    internal var failReads = false
    internal var failWrites = false

    internal func existing(
        judgeVersion: String,
        guid: String,
        inputHash: String
    ) async throws -> StowerReplyExpectation? {
        if failReads {
            throw StowerSpyJudgeError.forced
        }
        return nil
    }

    internal func upsert(
        judgeVersion: String,
        guid: String,
        inputHash: String,
        verdict: StowerReplyExpectation
    ) async throws {
        if failWrites {
            throw StowerSpyJudgeError.forced
        }
    }
}

/// A thread-safe call counter for scripting an availability-resolver closure.
internal final class StowerCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments and returns the new running count.
    internal func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
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
    userReactedToLastMessage: Bool = false,
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
        userReactedToLastMessage: userReactedToLastMessage,
        counterpartReactedToLastMessage: counterpartReactedToLastMessage,
        deepLink: nil
    )
    return StowerConversationStateRecord(state: state, lastMessageGUID: guid)
}
