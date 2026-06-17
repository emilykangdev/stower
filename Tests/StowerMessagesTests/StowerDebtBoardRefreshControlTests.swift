import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerDebtBoardProvider refresh control")
internal struct StowerDebtBoardRefreshControlTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Single-flight + availability on refresh

    @Test("two overlapping refreshes coalesce: one runs, the other returns nil, counts not split")
    internal func overlappingRefreshCoalesces() async throws {
        let records = sampleRecords()
        let spy = StowerSpyReplyJudge()
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: cache,
            modelAvailabilityResolver: {
                // Hold the in-flight pass long enough for the second to coalesce.
                try? await Task.sleep(for: .milliseconds(30))
                return .available
            }
        )

        async let first = provider.refreshJudgments(config: config(), now: now)
        async let second = provider.refreshJudgments(config: config(), now: now)
        let results: [StowerRefreshSummary?] = try await [first, second]

        let ran = results.compactMap { $0 }
        #expect(ran.count == 1)  // exactly one ran; the other coalesced (nil, never 0/0/0)
        #expect(ran.first?.totalCount == records.count)
        #expect(spy.callCount == records.count)  // counts not split / doubled
    }

    @Test("refresh throws languageModelUnavailable on a mid-session unavailable model")
    internal func refreshThrowsWhenUnavailable() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: sampleRecords()) },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: cache,
            modelAvailabilityResolver: { .unavailable(.appleIntelligenceNotEnabled) }
        )
        await #expect(throws: StowerMessagesError.self) {
            _ = try await provider.refreshJudgments(config: config(), now: now)
        }
    }

    @Test("refresh recovers once availability comes online after a downloading state")
    internal func refreshRecoversWhenAvailabilityReturns() async throws {
        let records = sampleRecords()
        let spy = StowerSpyReplyJudge()
        let cache = try StowerReplyVerdictCache.inMemory()
        let counter = StowerCallCounter()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: cache,
            modelAvailabilityResolver: {
                counter.next() > 1 ? .available : .unavailable(.modelNotReady)
            }
        )

        await #expect(throws: StowerMessagesError.self) {
            _ = try await provider.refreshJudgments(config: config(), now: now)
        }
        #expect(spy.callCount == 0)

        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.judgedCount > 0)
        #expect(spy.callCount > 0)
    }

    @Test("a load issued during an in-flight refresh still returns a board")
    internal func loadDuringRefreshReturnsBoard() async throws {
        let spy = StowerSpyReplyJudge()
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: sampleRecords()) },
            languageModelJudge: spy,
            cache: cache
        )

        async let refresh = provider.refreshJudgments(config: config(), now: now)
        async let load = provider.loadDebtBoard(config: config(), now: now)
        let (_, board) = try await (refresh, load)

        #expect(board.neglected.allSatisfy { $0.replyExpectationConfidence >= 0 })
    }

    // MARK: - Timeout vs cancellation

    @Test("a hung judge times out, counts the record failed, and the pass still completes")
    internal func hungJudgeTimesOutAndCompletes() async throws {
        let records = [
            stowerTestRecord(chatID: "slow", guid: "g-slow", lastMessageText: "you free?", now: now)
        ]
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: StowerHangingReplyJudge(),
            cache: cache
        )
        // Uses the named perRecordTimeout: the hung call is abandoned and counted
        // failed, so the pass returns with judged + failed == total.
        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.failedCount == 1)
        #expect(summary.judgedCount == 0)
        #expect(summary.judgedCount + summary.failedCount == summary.totalCount)
        #expect(summary.changedChatIDs.isEmpty)
    }

    @Test("a parent-cancelled pass leaves records uncounted (cancel ≠ timeout)")
    internal func parentCancelLeavesRecordsUncounted() async throws {
        let records = [
            stowerTestRecord(chatID: "a", guid: "g-a", lastMessageText: "you free?", now: now),
            stowerTestRecord(chatID: "b", guid: "g-b", lastMessageText: "you free?", now: now)
        ]
        let cache = try StowerReplyVerdictCache.inMemory()
        let judge = StowerHangingReplyJudge()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: judge,
            cache: cache
        )

        let task = Task { try await provider.refreshJudgments(config: config(), now: now) }
        // Let the pass enter the loop and start judging the first record, then cancel.
        while judge.callCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let summary = try #require(try await task.value)

        // Parent cancel breaks the loop UNCOUNTED — not counted as failed, so the
        // app sees judged + failed < total and re-issues (the loading stays up).
        #expect(summary.totalCount == records.count)
        #expect(summary.judgedCount + summary.failedCount < summary.totalCount)
    }

    // MARK: - Disposable cache

    @Test("a corrupt cache file is rebuilt, not left permanently disabling verdicts (M9)")
    internal func openCacheRebuildsCorruptStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-verdict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerReplyVerdictCache.fileName)
        try Data("this is not a sqlite database".utf8).write(to: url)

        let cache = try #require(StowerDebtBoardProvider.openCache(at: url))
        let verdict = StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: 0.7,
            verdictSource: .languageModel
        )
        try await cache.upsert(judgeVersion: "v1", guid: "g1", inputHash: "h1", verdict: verdict)
        let fetched = try await cache.existing(judgeVersion: "v1", guid: "g1", inputHash: "h1")
        #expect(fetched?.expectsReply == true)
    }

    // MARK: - Helpers

    private func config(unansweredForDays: Int = 7) -> StowerDebtConfig {
        StowerDebtConfig(unansweredForDays: unansweredForDays)
    }

    private func sampleRecords() -> [StowerConversationStateRecord] {
        [
            stowerTestRecord(
                chatID: "ask",
                guid: "g-ask",
                lastActor: .counterpart,
                lastMessageText: "can you send that file?",
                now: now
            ),
            stowerTestRecord(
                chatID: "chitchat",
                guid: "g-chit",
                lastActor: .counterpart,
                lastMessageText: "lol same",
                now: now
            )
        ]
    }
}
