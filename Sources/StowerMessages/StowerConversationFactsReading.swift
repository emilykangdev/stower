import Foundation

/// The facts surface the debt-board provider reads, abstracted for testing.
///
/// `StowerChatDatabaseReader` is the production conformer; tests inject a
/// synthetic source so the provider can be exercised without a real `chat.db`.
/// The provider builds a fresh conformer per `loadDebtBoard` (M3), so a snapshot
/// taken once at the reader's `init` is always current.
internal protocol StowerConversationFactsReading: Sendable {
    /// Returns per-1:1 facts paired with each conversation's last-act GUID.
    func conversationStateRecords(
        windowDays: Int,
        now: Date
    ) async throws -> [StowerConversationStateRecord]

    /// Returns the newest messages of one chat as lightweight thread rows.
    func threadMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage]
}

extension StowerChatDatabaseReader: StowerConversationFactsReading {}
