import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerDebtBoardProvider")
internal struct StowerDebtBoardProviderTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Judged-only load

    @Test("loadDebtBoard issues zero model calls — judgments happen only in refresh")
    internal func loadNeverCallsModel() async throws {
        let spy = StowerSpyReplyJudge()
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = makeProvider(judge: spy, cache: cache)

        _ = try await provider.loadDebtBoard(config: config(), now: now)

        #expect(spy.callCount == 0)
    }

    @Test("a cold cache serves no rows — unjudged conversations are excluded")
    internal func coldCacheServesNoRows() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = makeProvider(judge: StowerSpyReplyJudge(), cache: cache)

        let board = try await provider.loadDebtBoard(config: config(), now: now)

        #expect(board.neglected.isEmpty)
        #expect(board.ghosted.isEmpty)
    }

    @Test("a faulty cache read serves no rows and never calls the model (M9)")
    internal func faultyCacheServesNoRows() async throws {
        let spy = StowerSpyReplyJudge()
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: sampleRecords()) },
            languageModelJudge: spy,
            cache: StowerFaultyVerdictCache(failReads: true)
        )

        let board = try await provider.loadDebtBoard(config: config(), now: now)

        #expect(board.neglected.isEmpty)
        #expect(board.ghosted.isEmpty)
        #expect(spy.callCount == 0)
    }

    @Test("refresh fills the cache; a later load serves the judged rows, no model on load")
    internal func refreshThenLoadServesJudgedRows() async throws {
        let spy = StowerSpyReplyJudge(verdict: { _ in
            StowerReplyExpectation(
                expectsReply: true,
                replyExpectationConfidence: 0.91,
                verdictSource: .languageModel
            )
        })
        let cache = try StowerReplyVerdictCache.inMemory()
        let provider = makeProvider(judge: spy, cache: cache)

        let cold = try await provider.loadDebtBoard(config: config(), now: now)
        #expect(cold.neglected.isEmpty)

        let summary = try await provider.refreshJudgments(config: config(), now: now)
        #expect((summary?.judgedCount ?? 0) > 0)
        let afterRefresh = spy.callCount
        #expect(afterRefresh > 0)

        let warm = try await provider.loadDebtBoard(config: config(), now: now)
        #expect(!warm.neglected.isEmpty)

        // Flipping a runtime filter re-runs gate+rank only — never the model.
        _ = try await provider.loadDebtBoard(config: config(unansweredForDays: 1), now: now)
        #expect(spy.callCount == afterRefresh)
    }

    @Test("a changed judge version misses the cache, excluding the row (no fallback verdict)")
    internal func judgeVersionChangeExcludesRow() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let records = sampleRecords()
        let writer = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: StowerSpyReplyJudge(judgeVersion: "v1"),
            cache: cache
        )
        _ = try await writer.refreshJudgments(config: config(), now: now)

        let reader = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: records) },
            languageModelJudge: StowerSpyReplyJudge(judgeVersion: "v2"),
            cache: cache
        )
        let board = try await reader.loadDebtBoard(config: config(), now: now)
        #expect(board.neglected.isEmpty)
        #expect(board.ghosted.isEmpty)
    }

    @Test("a case-only edit changes the input hash, forcing a re-judge (M11)")
    internal func caseOnlyEditMissesCache() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let spy = StowerSpyReplyJudge()
        let mixed = [
            stowerTestRecord(chatID: "c", guid: "g", lastMessageText: "Are We On?", now: now)
        ]
        let lower = [
            stowerTestRecord(chatID: "c", guid: "g", lastMessageText: "are we on?", now: now)
        ]

        let first = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: mixed) },
            languageModelJudge: spy,
            cache: cache
        )
        _ = try await first.refreshJudgments(config: config(), now: now)
        #expect(spy.callCount == 1)

        let second = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: lower) },
            languageModelJudge: spy,
            cache: cache
        )
        _ = try await second.refreshJudgments(config: config(), now: now)
        // Same guid, case-only text change ⇒ different input hash ⇒ re-judged.
        #expect(spy.callCount == 2)
    }

    // MARK: - Availability ordering

    @Test("an unavailable model throws before the reader opens chat.db, for every reason")
    internal func unavailableThrowsBeforeReader() async throws {
        let reasons: [StowerModelUnavailableReason] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unknown
        ]
        for reason in reasons {
            let provider = StowerDebtBoardProvider(
                readerFactory: {
                    throw StowerMessagesError.fullDiskAccessMissing("/should-not-open")
                },
                languageModelJudge: StowerSpyReplyJudge(),
                cache: nil,
                modelAvailabilityResolver: { .unavailable(reason) }
            )
            do {
                _ = try await provider.loadDebtBoard(config: config(), now: now)
                Issue.record("expected loadDebtBoard to throw for \(reason)")
            } catch let error as StowerMessagesError {
                guard case .languageModelUnavailable(let got) = error else {
                    Issue.record("expected languageModelUnavailable, got \(error)")
                    continue
                }
                #expect(got == reason)
            }
        }
    }

    @Test("a supported model still surfaces a Full Disk Access error from the reader")
    internal func supportedSurfacesFDA() async throws {
        let provider = StowerDebtBoardProvider(
            readerFactory: { throw StowerMessagesError.fullDiskAccessMissing("/x") },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: nil
        )
        do {
            _ = try await provider.loadDebtBoard(config: config(), now: now)
            Issue.record("expected loadDebtBoard to throw")
        } catch let error as StowerMessagesError {
            guard case .fullDiskAccessMissing = error else {
                Issue.record("expected fullDiskAccessMissing, got \(error)")
                return
            }
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

    // MARK: - Helpers

    private func makeProvider(
        judge: StowerReplyExpectationJudge?,
        cache: StowerReplyVerdictCaching?
    ) -> StowerDebtBoardProvider {
        StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: sampleRecords()) },
            languageModelJudge: judge,
            cache: cache
        )
    }

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
