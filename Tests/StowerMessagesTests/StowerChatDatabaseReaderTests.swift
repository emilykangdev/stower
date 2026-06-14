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
        // Groups get NO deep link: an sms: recipient-set compose creates a
        // NEW group instead of matching the existing one (real-data check).
        #expect(items.first(where: { $0.id == "group-incoming" })?.deepLink == nil)
        // Reserved URL characters in an email identifier must be percent-encoded
        // so the link opens the right conversation instead of a truncated one.
        #expect(
            items.first(where: { $0.id == "reserved-incoming" })?.deepLink?.absoluteString
                == "sms:od%23d@example.com"
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

    @Test("isOneToOne reflects chat style on the item")
    internal func isOneToOneSurfaced() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let reader = try StowerChatDatabaseReader(
            sourceURL: fixture.databaseURL,
            contactsResolver: contacts
        )

        let items = try await reader.ingestWindow(days: 180, now: StowerFixtureDatabase.now)
        #expect(items.first(where: { $0.id == "incoming" })?.isOneToOne == true)
        #expect(items.first(where: { $0.id == "bea-incoming" })?.isOneToOne == true)
        #expect(items.first(where: { $0.id == "group-incoming" })?.isOneToOne == false)
    }

    @Test("conversationStates emits one neutral state per 1:1 chat, never groups")
    internal func conversationStates() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let reader = try StowerChatDatabaseReader(
            sourceURL: fixture.databaseURL,
            contactsResolver: contacts
        )

        let states = try await reader.conversationStates(now: StowerFixtureDatabase.now)
        let byChat = Dictionary(uniqueKeysWithValues: states.map { ($0.chatID, $0) })

        #expect(states.allSatisfy { $0.isOneToOne })
        #expect(byChat["chat-group"] == nil)
        // Inbound photo newer than text ⇒ surfaced kind, nil text, counterpart last.
        let photo = try #require(byChat["chat-inbound-photo"])
        #expect(photo.lastActor == .counterpart)
        #expect(photo.lastMessageKind == .attachment)
        #expect(photo.lastMessageText == nil)
        // Outbound photo after their text ⇒ user acted last.
        #expect(byChat["chat-outbound-attach"]?.lastActor == .user)
        // A system row newer than their text must not flip the last actor.
        #expect(byChat["chat-system"]?.lastActor == .counterpart)
        // Items-less chat falls back to the raw handle for its title.
        #expect(byChat["chat-attach-react"]?.counterpart == "+14155550604")
    }

    @Test("noReplyCandidates applies mutuality, clearing, and the threshold over the fixture")
    internal func noReplyCandidates() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let reader = try StowerChatDatabaseReader(
            sourceURL: fixture.databaseURL,
            contactsResolver: contacts
        )

        let candidates = try await reader.noReplyCandidates(
            unansweredForDays: 1,
            now: StowerFixtureDatabase.now
        )
        let ids = Set(candidates.map(\.chatID))

        // Surfaced: netted-out reaction, old reaction, reaction-mutuality, photo, system.
        #expect(ids.contains("chat-removed"))
        #expect(ids.contains("chat-oldreact"))
        #expect(ids.contains("chat-attach-react"))
        #expect(ids.contains("chat-inbound-photo"))
        #expect(ids.contains("chat-system"))
        // Cleared by a tapback on the last message (bare + prefixed targets).
        #expect(!ids.contains("chat-clears"))
        #expect(!ids.contains("chat-prefixed"))
        // Excluded: user acted last, and a stale thread with no recent reciprocity.
        #expect(!ids.contains("chat-outbound-attach"))
        #expect(!ids.contains("chat-stale"))
        // Groups never appear.
        #expect(!ids.contains("chat-group"))
        // Ranked most-recently-unanswered first.
        #expect(
            candidates.map(\.lastMessageTimestamp)
                == candidates.map(\.lastMessageTimestamp).sorted(by: >)
        )
    }

    @Test("noReplyCandidates rejects negative arguments")
    internal func noReplyCandidatesValidatesArguments() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let reader = try StowerChatDatabaseReader(
            sourceURL: fixture.databaseURL,
            contactsResolver: contacts
        )

        await #expect(throws: StowerMessagesError.self) {
            _ = try await reader.noReplyCandidates(
                unansweredForDays: -1,
                now: StowerFixtureDatabase.now
            )
        }
        await #expect(throws: StowerMessagesError.self) {
            _ = try await reader.noReplyCandidates(
                unansweredForDays: 1,
                minimumReciprocity: -1,
                now: StowerFixtureDatabase.now
            )
        }
        // A threshold beyond the read window could only match unread history.
        await #expect(throws: StowerMessagesError.self) {
            _ = try await reader.noReplyCandidates(
                unansweredForDays: 200,
                windowDays: 180,
                now: StowerFixtureDatabase.now
            )
        }
    }

    private var contacts: StowerContactsResolver {
        let mapping = ["+14155550100": "Alex", "sam@example.com": "Sam"]
        return StowerContactsResolver(mapping: mapping)
    }
}
