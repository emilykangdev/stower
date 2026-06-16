import Foundation
import Testing

@testable import StowerMessages

/// A minimal `StowerDebtBoardProviding` mock standing in for the app's own
/// test double.
///
/// Its existence keeps the locked protocol from drifting: if the seam the app
/// depends on changes shape, this stops compiling (M5).
private struct StowerMockDebtBoardProvider: StowerDebtBoardProviding {
    func modelAvailability() async -> StowerModelAvailability {
        .available
    }

    func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard {
        StowerDebtBoard(neglected: [], ghosted: [])
    }

    func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage] {
        []
    }

    func refreshJudgments(
        config: StowerDebtConfig,
        now: Date
    ) async throws -> StowerRefreshSummary? {
        StowerRefreshSummary(changedChatIDs: [], judgedCount: 0, failedCount: 0, totalCount: 0)
    }
}

@Suite("StowerDebtBoard contract")
internal struct StowerDebtBoardContractTests {
    @Test("the app's expected provider usage compiles and round-trips through the seam")
    internal func contractUsageCompiles() async throws {
        // The app holds the engine behind the existential, exactly like this.
        let provider: any StowerDebtBoardProviding = StowerMockDebtBoardProvider()
        let config = StowerDebtConfig(
            unansweredForDays: 7,
            minimumReciprocity: 1,
            ghostGateThreshold: 0.5
        )

        #expect(await provider.modelAvailability() == .available)

        let board = try await provider.loadDebtBoard(config: config, now: Date())
        #expect(board.neglected.isEmpty)
        #expect(board.ghosted.isEmpty)

        let thread = try await provider.recentMessages(chatID: "chat-1", limit: 20)
        #expect(thread.isEmpty)

        let summary = try await provider.refreshJudgments(config: config, now: Date())
        #expect(summary?.judgedCount == 0)
        #expect(summary?.failedCount == 0)
        #expect(summary?.totalCount == 0)

        // The concrete provider's public init is part of the same contract — the
        // app must supply a `modelIdentity` epoch (no default).
        _ = StowerDebtBoardProvider(
            sourceURL: URL(fileURLWithPath: "/x"),
            cacheURL: nil,
            modelIdentity: "contract-epoch-1"
        )
    }

    @Test("a debt row carries only display facts plus the model's confidence")
    internal func rowIsCollapsedToConfidenceOnly() {
        // The collapsed row constructs from display fields + a single confidence —
        // no verdictSource / expectsReply / pending / reason discriminator. If any
        // of those were re-added the keyword init below would stop compiling.
        let row = StowerDebtItem(
            chatID: "c",
            chatTitle: "Title",
            counterpart: "Alex",
            counterpartHandle: "+15551234",
            lastMessageKind: .text,
            lastMessageText: "are we still on?",
            lastMessageTimestamp: Date(timeIntervalSinceReferenceDate: 0),
            deepLink: nil,
            replyExpectationConfidence: 0.82
        )
        #expect(row.replyExpectationConfidence == 0.82)
        #expect(row.chatID == "c")
    }
}
