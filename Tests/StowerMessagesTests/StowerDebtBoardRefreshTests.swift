import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerDebtBoardProvider refresh")
internal struct StowerDebtBoardRefreshTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Refresh progress

    @Test("an empty snapshot completes at 0/0/0")
    internal func emptySnapshotCompletes() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: []) },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: cache
        )
        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.judgedCount == 0)
        #expect(summary.failedCount == 0)
        #expect(summary.totalCount == 0)
    }

    @Test("refresh progress counts existing hits, new writes, and failures exactly")
    internal func refreshProgressIsExact() async throws {
        let records = [
            stowerTestRecord(chatID: "hit", guid: "g-hit", lastMessageText: "hit", now: now),
            stowerTestRecord(chatID: "win", guid: "g-win", lastMessageText: "win", now: now),
            stowerTestRecord(chatID: "bad", guid: "g-bad", lastMessageText: "bad", now: now)
        ]
        let cache = try StowerReplyVerdictCache.inMemory()
        let spy = StowerSpyReplyJudge(verdict: { text in
            // An out-of-range confidence for "bad" models an invalid judge result.
            let confidence = text == "bad" ? 5.0 : 0.9
            return StowerReplyExpectation(
                expectsReply: true,
                replyExpectationConfidence: confidence,
                verdictSource: .languageModel
            )
        })

        // Seed "hit" via a first refresh so its cached hash matches exactly.
        let seed = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: [records[0]]) },
            languageModelJudge: spy,
            cache: cache
        )
        _ = try await seed.refreshJudgments(config: config(), now: now)

        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: cache
        )
        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.totalCount == 3)
        #expect(summary.judgedCount == 2)  // hit (existing) + win (new write)
        #expect(summary.failedCount == 1)  // bad (invalid confidence)
        #expect(summary.judgedCount + summary.failedCount == summary.totalCount)
        #expect(summary.changedChatIDs == ["win"])
    }

    @Test("a no-cache pass reports all records failed so loading still clears")
    internal func noCacheReportsAllFailed() async throws {
        let records = sampleRecords()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: nil
        )
        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.judgedCount == 0)
        #expect(summary.failedCount == records.count)
        #expect(summary.totalCount == records.count)
    }

    @Test("a first-run absent cache is created and judges normally, not reported all-failed")
    internal func firstRunCacheCreatedNotFailed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-verdict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerReplyVerdictCache.fileName)

        // No file exists yet; openCache must CREATE it (not fail) so refresh judges in.
        let cache = try #require(StowerDebtBoardProvider.openCache(at: url))
        let records = sampleRecords()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: cache
        )
        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.judgedCount == records.count)
        #expect(summary.failedCount == 0)
        #expect(summary.totalCount == records.count)
    }

    @Test("an invalid judge result is not written and is counted failed, not silently dropped")
    internal func invalidVerdictCountedFailedNotWritten() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let records = sampleRecords()
        let spy = StowerSpyReplyJudge(verdict: { _ in
            StowerReplyExpectation(
                expectsReply: true,
                replyExpectationConfidence: 5.0,
                verdictSource: .languageModel
            )
        })
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: cache
        )
        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.judgedCount == 0)
        #expect(summary.failedCount == records.count)
        #expect(summary.changedChatIDs.isEmpty)

        // Nothing trusted got written ⇒ a later load still serves no rows.
        let board = try await provider.loadDebtBoard(config: config(), now: now)
        #expect(board.neglected.isEmpty)
    }

    @Test("a failed cache write is counted failed and not reported as a changed chat")
    internal func failedWriteCountedFailedNotChanged() async throws {
        let records = sampleRecords()
        let spy = StowerSpyReplyJudge()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: StowerFaultyVerdictCache(failWrites: true)
        )
        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(spy.callCount == records.count)
        #expect(summary.changedChatIDs.isEmpty)
        #expect(summary.failedCount == records.count)
        #expect(summary.judgedCount == 0)
    }

    @Test("refresh judges the most-recently-active threads first")
    internal func refreshPrioritizesRecentThreads() async throws {
        let records = [
            stowerTestRecord(
                chatID: "old",
                guid: "g-old",
                lastMessageText: "you free?",
                daysAgo: 40,
                now: now
            ),
            stowerTestRecord(
                chatID: "new",
                guid: "g-new",
                lastMessageText: "you free?",
                daysAgo: 2,
                now: now
            ),
            stowerTestRecord(
                chatID: "mid",
                guid: "g-mid",
                lastMessageText: "you free?",
                daysAgo: 20,
                now: now
            )
        ]
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: cache
        )

        let summary = try #require(try await provider.refreshJudgments(config: config(), now: now))
        #expect(summary.changedChatIDs == ["new", "mid", "old"])
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
