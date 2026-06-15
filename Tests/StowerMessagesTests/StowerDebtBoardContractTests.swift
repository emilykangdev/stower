import Foundation
import Testing

@testable import StowerMessages

/// A minimal `StowerDebtBoardProviding` mock standing in for the app's own
/// test double.
///
/// Its existence keeps the locked protocol from drifting: if the seam the app
/// depends on changes shape, this stops compiling (M5).
private struct StowerMockDebtBoardProvider: StowerDebtBoardProviding {
    func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard {
        StowerDebtBoard(neglected: [], ghosted: [])
    }

    func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage] {
        []
    }

    func refreshJudgments(config: StowerDebtConfig, now: Date) async -> StowerRefreshSummary {
        StowerRefreshSummary(changedChatIDs: [])
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
            judgeMode: .automatic,
            ghostGateThreshold: 0.5
        )

        let board = try await provider.loadDebtBoard(config: config, now: Date())
        #expect(board.neglected.isEmpty)
        #expect(board.ghosted.isEmpty)

        let thread = try await provider.recentMessages(chatID: "chat-1", limit: 20)
        #expect(thread.isEmpty)

        let summary = await provider.refreshJudgments(config: config, now: Date())
        #expect(summary.changedCount == 0)

        // The concrete provider's public init is part of the same contract.
        _ = StowerDebtBoardProvider(sourceURL: URL(fileURLWithPath: "/x"), cacheURL: nil)
    }
}
