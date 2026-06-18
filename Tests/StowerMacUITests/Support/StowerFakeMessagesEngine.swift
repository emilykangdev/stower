import Foundation
import StowerMessages

/// A Tests-only `StowerDebtBoardProviding` conformer for the adapter-mapping
/// tests.
///
/// It throws a chosen real `StowerMessagesError` (or a chosen availability) so a
/// test can assert how `StowerMessagesStartupAdapter` translates each one. The
/// `recentMessages` / `refreshJudgments` methods are unused by these tests and
/// fail loudly if reached, so a wrong call never passes silently.
internal struct StowerFakeMessagesEngine: StowerDebtBoardProviding {
    internal var availability: StowerModelAvailability = .available
    internal var loadError: StowerMessagesError?

    internal func modelAvailability() async -> StowerModelAvailability {
        availability
    }

    internal func loadDebtBoard(
        config: StowerDebtConfig,
        now: Date
    ) async throws -> StowerDebtBoard {
        if let loadError {
            throw loadError
        }
        return StowerDebtBoard(neglected: [], ghosted: [])
    }

    internal func recentMessages(
        chatID: String,
        limit: Int
    ) async throws -> [StowerThreadMessage] {
        throw StowerFakeMessagesEngineUnused.called
    }

    internal func refreshJudgments(
        config: StowerDebtConfig,
        now: Date
    ) async throws -> StowerRefreshSummary? {
        throw StowerFakeMessagesEngineUnused.called
    }
}

/// Thrown if an unused engine method is reached, so a stray call fails loudly.
internal enum StowerFakeMessagesEngineUnused: Error {
    case called
}
