import Foundation

/// The facts surface the debt-board provider reads, abstracted for testing.
///
/// `StowerChatDatabaseReader` is the production conformer; tests inject a
/// synthetic source so the provider can be exercised without a real `chat.db`.
/// The provider opens/reuses ONE reader across loads and thread taps;
/// `refreshJudgments` rebuilds it, so a board load between refreshes reads the same
/// snapshot the cache was built against.
internal protocol StowerConversationFactsReading: Sendable {
    /// Returns per-1:1 facts paired with each conversation's last-act GUID.
    func conversationStateRecords(
        windowDays: Int,
        now: Date
    ) async throws -> [StowerConversationStateRecord]

    /// Returns the newest `limit` messages of one chat as lightweight thread rows,
    /// ordered oldest-first for display.
    func threadMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage]
}

extension StowerChatDatabaseReader: StowerConversationFactsReading {}
