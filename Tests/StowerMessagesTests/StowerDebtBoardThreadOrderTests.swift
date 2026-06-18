import Testing

@testable import StowerMessages

/// Pins the two-part `recentMessages` contract at the PROVIDER seam the app
/// depends on: the newest `limit` messages, returned **oldest-first** for display.
///
/// The app preserves this order 1:1 and cannot re-derive it — `StowerThreadMessage`
/// carries no sequence to sort by, and a `timestamp`-only sort would scramble
/// same-second ties. So a regression that drops the reader's reversal (or changes
/// the newest-`limit` selection) must fail the build here, not silently flip every
/// thread upside-down in the UI.
@Suite("StowerDebtBoardProvider.recentMessages order")
internal struct StowerDebtBoardThreadOrderTests {
    @Test("recentMessages returns the newest limit, oldest-first")
    internal func recentMessagesNewestLimitOldestFirst() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let provider = makeProvider(over: fixture)

        let newest = try await provider.recentMessages(chatID: "chat-alex", limit: 3)
        let full = try await provider.recentMessages(chatID: "chat-alex", limit: 100)

        // Newest-3 selection, returned oldest-first (the most recent is last).
        #expect(newest.map(\.id) == ["tie-a", "tie-b", "newest"])
        // Oldest-first across the whole thread (ascending timestamps), and the
        // unbounded read reaches back to the oldest row.
        #expect(full.map(\.timestamp) == full.map(\.timestamp).sorted())
        #expect(full.contains(where: { $0.id == "old" }))
        #expect(full.last?.id == "newest")
    }

    private func makeProvider(over fixture: StowerFixtureDatabase) -> StowerDebtBoardProvider {
        let url = fixture.databaseURL
        let resolver = StowerContactsResolver(
            mapping: ["+14155550100": "Alex", "sam@example.com": "Sam"]
        )
        return StowerDebtBoardProvider(
            readerFactory: {
                try StowerChatDatabaseReader(sourceURL: url, contactsResolver: resolver)
            },
            languageModelJudge: nil,
            cache: nil
        )
    }
}
