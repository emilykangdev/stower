import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerDebtBoardProvider")
internal struct StowerDebtBoardProviderTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("loadDebtBoard issues zero model calls — judgments happen only in refresh")
    internal func loadNeverCallsModel() async throws {
        let spy = StowerSpyReplyJudge()
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = makeProvider(languageModelJudge: spy, cache: cache)

        _ = try await provider.loadDebtBoard(config: config(), now: now)

        #expect(spy.callCount == 0)
    }

    @Test("availability off ⇒ every row is heuristic; no cached model verdict exists")
    internal func availabilityOffYieldsHeuristic() async throws {
        let provider = makeProvider(languageModelJudge: nil, cache: nil)

        let board = try await provider.loadDebtBoard(config: config(), now: now)

        #expect(!board.neglected.isEmpty)
        #expect(board.neglected.allSatisfy { $0.verdictSource == .heuristic })
    }

    @Test("refresh fills the cache; a later load reflects model verdicts, no re-invoke")
    internal func refreshThenLoadUsesCachedModelVerdicts() async throws {
        let spy = StowerSpyReplyJudge(verdict: { _ in
            StowerReplyExpectation(
                expectsReply: true,
                replyExpectationConfidence: 0.91,
                verdictSource: .languageModel
            )
        })
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = makeProvider(languageModelJudge: spy, cache: cache)

        let firstLoad = try await provider.loadDebtBoard(config: config(), now: now)
        #expect(firstLoad.neglected.allSatisfy { $0.verdictSource == .heuristic })

        let summary = await provider.refreshJudgments(config: config(), now: now)
        #expect(summary.changedCount > 0)
        let afterRefresh = spy.callCount
        #expect(afterRefresh > 0)

        let secondLoad = try await provider.loadDebtBoard(config: config(), now: now)
        #expect(secondLoad.neglected.contains { $0.verdictSource == .languageModel })

        // Flipping a runtime filter re-runs gate+rank only — never the model.
        _ = try await provider.loadDebtBoard(config: config(unansweredForDays: 1), now: now)
        #expect(spy.callCount == afterRefresh)
    }

    @Test("a changed judge version misses the cache, so the load falls back to heuristic")
    internal func judgeVersionChangeMissesCache() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let writer = makeProvider(
            languageModelJudge: StowerSpyReplyJudge(judgeVersion: "v1"),
            cache: cache
        )
        _ = await writer.refreshJudgments(config: config(), now: now)

        let reader = makeProvider(
            languageModelJudge: StowerSpyReplyJudge(judgeVersion: "v2"),
            cache: cache
        )
        let board = try await reader.loadDebtBoard(config: config(), now: now)
        #expect(board.neglected.allSatisfy { $0.verdictSource == .heuristic })
    }

    @Test("a model error during refresh caches nothing as .languageModel (M13)")
    internal func modelErrorNotCached() async throws {
        let throwing = StowerSpyReplyJudge(shouldThrow: true)
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = makeProvider(languageModelJudge: throwing, cache: cache)

        let summary = await provider.refreshJudgments(config: config(), now: now)
        #expect(summary.changedCount == 0)

        let board = try await provider.loadDebtBoard(config: config(), now: now)
        #expect(board.neglected.allSatisfy { $0.verdictSource == .heuristic })
    }

    @Test("a missing-Full-Disk-Access reader surfaces a typed error")
    internal func fullDiskAccessErrorPropagates() async {
        let provider = StowerDebtBoardProvider(
            readerFactory: { throw StowerMessagesError.fullDiskAccessMissing("/x") },
            languageModelJudge: nil,
            cache: nil
        )
        await #expect(throws: StowerMessagesError.self) {
            _ = try await provider.loadDebtBoard(config: config(), now: now)
        }
    }

    @Test("a threshold beyond the read window fails loud, not to an empty board")
    internal func thresholdBeyondWindowThrows() async {
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: []) },
            languageModelJudge: nil,
            cache: nil,
            windowDays: 30
        )
        await #expect(throws: StowerMessagesError.self) {
            _ = try await provider.loadDebtBoard(
                config: StowerDebtConfig(unansweredForDays: 60),
                now: now
            )
        }
    }

    @Test("two overlapping refreshes judge each guid at most once (M16)")
    internal func concurrentRefreshDoesNotDoubleCall() async throws {
        let records = sampleRecords()
        let spy = StowerSpyReplyJudge()
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: cache
        )

        async let first = provider.refreshJudgments(config: config(), now: now)
        async let second = provider.refreshJudgments(config: config(), now: now)
        _ = await (first, second)

        // Every reply-expecting guid judged once total, never twice.
        #expect(spy.callCount == records.count)
    }

    @Test("a load issued during an in-flight refresh still returns a board")
    internal func loadDuringRefreshStaysStructural() async throws {
        let spy = StowerSpyReplyJudge()
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = makeProvider(languageModelJudge: spy, cache: cache)

        async let refresh = provider.refreshJudgments(config: config(), now: now)
        async let load = provider.loadDebtBoard(config: config(), now: now)
        let (_, board) = try await (refresh, load)

        #expect(!board.neglected.isEmpty)
    }

    @Test("a cache read fault degrades the load to heuristic without blocking (M9)")
    internal func loadSurvivesCacheReadFault() async throws {
        let records = sampleRecords()
        let spy = StowerSpyReplyJudge()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: StowerFaultyVerdictCache(failReads: true)
        )

        let board = try await provider.loadDebtBoard(config: config(), now: now)

        // The cache threw, but the board still built on heuristic verdicts and the
        // load never reached the model.
        #expect(spy.callCount == 0)
        #expect(!board.neglected.isEmpty)
        #expect(board.neglected.allSatisfy { $0.verdictSource == .heuristic })
    }

    @Test("a failed cache write is not reported as a changed chat")
    internal func refreshDoesNotReportUnpersistedChange() async throws {
        let records = sampleRecords()
        let spy = StowerSpyReplyJudge()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: spy,
            cache: StowerFaultyVerdictCache(failWrites: true)
        )

        let summary = await provider.refreshJudgments(config: config(), now: now)

        // The model ran, but nothing persisted, so no chat is reported changed —
        // the app must not reload to the same heuristic verdict.
        #expect(spy.callCount == records.count)
        #expect(summary.changedCount == 0)
    }

    @Test("the provider recovers the model judge when availability turns on later")
    internal func resolvesLanguageModelJudgeLazily() async throws {
        let records = sampleRecords()
        let cache = try StowerReplyVerdictCache.inMemory()
        let spy = StowerSpyReplyJudge()
        let counter = StowerCallCounter()
        // Availability is off at construction, then comes online: the resolver
        // yields nil the first time and the judge thereafter.
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: nil,
            cache: cache,
            languageModelJudgeResolver: { counter.next() > 1 ? spy : nil }
        )

        let first = await provider.refreshJudgments(config: config(), now: now)
        #expect(first.changedCount == 0)
        #expect(spy.callCount == 0)

        let second = await provider.refreshJudgments(config: config(), now: now)
        #expect(second.changedCount > 0)
        #expect(spy.callCount > 0)
    }

    @Test("a corrupt cache file is rebuilt, not left permanently disabling verdicts (M9)")
    internal func openCacheRebuildsCorruptStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-verdict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerReplyVerdictCache.fileName)
        try Data("this is not a sqlite database".utf8).write(to: url)

        // openCache must drop the unusable file and return a working cache — not
        // nil, which would dead-disable model verdicts for the provider's life.
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

        let summary = await provider.refreshJudgments(config: config(), now: now)

        // Verdicts are upserted in processing order, so the newest thread is
        // judged first and its smart verdict is available to the next load soonest.
        #expect(summary.changedChatIDs == ["new", "mid", "old"])
    }

    // MARK: - Helpers

    private func makeProvider(
        languageModelJudge: StowerReplyExpectationJudge?,
        cache: StowerReplyVerdictCache?
    ) -> StowerDebtBoardProvider {
        let records = sampleRecords()
        return StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: languageModelJudge,
            cache: cache
        )
    }

    private func config(unansweredForDays: Int = 7) -> StowerDebtConfig {
        StowerDebtConfig(unansweredForDays: unansweredForDays, judgeMode: .automatic)
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
