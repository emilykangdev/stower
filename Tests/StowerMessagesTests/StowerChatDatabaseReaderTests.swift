import Testing

@testable import StowerMessages

@Suite("StowerChatDatabaseReader")
internal struct StowerChatDatabaseReaderTests {
    @Test("windowed ingest decodes, filters, resolves names, and deduplicates")
    internal func ingestWindow() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let reader = try StowerChatDatabaseReader(
            sourceURL: fixture.databaseURL,
            contactsResolver: contacts
        )

        let items = try await reader.ingestWindow(days: 180, now: StowerFixtureDatabase.now)
        let ids = items.map(\.id)

        #expect(!ids.contains("old"))
        #expect(!ids.contains("tapback"))
        #expect(!ids.contains("system"))
        #expect(!ids.contains("attachment"))
        #expect(!ids.contains("balloon"))
        #expect(!ids.contains("zero"))
        #expect(items.first(where: { $0.id == "link" })?.text == "https://example.com/article")
        // Deep link must use chat_identifier, not the alphabetically-first
        // participant handle (a stale old number/email opens the wrong chat).
        #expect(
            items.first(where: { $0.id == "bea-incoming" })?.deepLink?.absoluteString
                == "sms:+14155550300"
        )
        // Group deep links carry the full recipient set (best-effort match).
        #expect(
            items.first(where: { $0.id == "group-incoming" })?.deepLink?.absoluteString
                == "sms:+14155550100,sam@example.com"
        )
        #expect(ids.filter { $0 == "duplicate" }.count == 1)
        #expect(items.first(where: { $0.id == "incoming" })?.text == "incoming NS Attribute")
        #expect(items.first(where: { $0.id == "outgoing" })?.groupTitle == "Alex")
        #expect(items.first(where: { $0.id == "outgoing" })?.sender == "Me")
        #expect(items.first(where: { $0.id == "group-incoming" })?.groupTitle == "Project Group")
        #expect(items.first(where: { $0.id == "group-incoming" })?.sender == "Sam")
    }

    @Test("recent messages are unbounded, newest-N, stable, and chronological")
    internal func recentMessages() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let reader = try StowerChatDatabaseReader(
            sourceURL: fixture.databaseURL,
            contactsResolver: contacts
        )

        let newest = try await reader.recentMessages(chatID: "chat-alex", limit: 3)
        let full = try await reader.recentMessages(chatID: "chat-alex", limit: 100)

        #expect(newest.map(\.id) == ["tie-a", "tie-b", "newest"])
        #expect(full.contains(where: { $0.id == "old" }))
        #expect(full.map(\.timestamp) == full.map(\.timestamp).sorted())
        #expect(full.first(where: { $0.id == "incoming" })?.sender == "Alex")
        #expect(full.first(where: { $0.id == "outgoing" })?.sender == "Me")
    }

    private var contacts: StowerContactsResolver {
        let mapping = ["+14155550100": "Alex", "sam@example.com": "Sam"]
        return StowerContactsResolver(mapping: mapping)
    }
}
