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

    @Test("the thread view keeps attachments and app messages, not just text")
    internal func threadMessagesIncludeNonText() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let reader = try StowerChatDatabaseReader(
            sourceURL: fixture.databaseURL,
            contactsResolver: contacts
        )

        let thread = try await reader.threadMessages(chatID: "chat-alex", limit: 100)
        let byID = Dictionary(uniqueKeysWithValues: thread.map { ($0.id, $0) })

        // The text-only index query dropped these; the thread view must keep them
        // so a photo or app message you exchanged never vanishes from the thread.
        #expect(byID["attachment"]?.kind == .attachment)
        #expect(byID["attachment"]?.text == nil)
        #expect(byID["balloon"]?.kind == .app)
        // Reactions and system rows still never appear as thread messages.
        #expect(byID["tapback"] == nil)
        #expect(byID["system"] == nil)
        // Text rows still decode and the thread stays chronological.
        #expect(byID["outgoing"]?.text == "outgoing text")
        #expect(thread.map(\.timestamp) == thread.map(\.timestamp).sorted())
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

    @Test("the Neglected lens applies mutuality, clearing, and the threshold over the fixture")
    internal func neglectedOverFixture() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }

        let board = try await provider(over: fixture).loadDebtBoard(
            config: StowerDebtConfig(unansweredForDays: 1, judgeMode: .heuristic),
            now: StowerFixtureDatabase.now
        )
        let ids = Set(board.neglected.map(\.chatID))

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
        // Ranked: expectsReply-true first, then most-recently-unanswered.
        let expectsFirst =
            board.neglected.map(\.expectsReply)
            == board.neglected.map(\.expectsReply).sorted(by: { $0 && !$1 })
        #expect(expectsFirst)
    }

    @Test("negative knobs fail closed to an empty board, never inverting a gate")
    internal func negativeKnobsFailClosed() async throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let prov = provider(over: fixture)

        let negativeDays = try await prov.loadDebtBoard(
            config: StowerDebtConfig(unansweredForDays: -1, judgeMode: .heuristic),
            now: StowerFixtureDatabase.now
        )
        #expect(negativeDays.neglected.isEmpty)
        #expect(negativeDays.ghosted.isEmpty)

        let negativeReciprocity = try await prov.loadDebtBoard(
            config: StowerDebtConfig(
                unansweredForDays: 1,
                minimumReciprocity: -1,
                judgeMode: .heuristic
            ),
            now: StowerFixtureDatabase.now
        )
        #expect(negativeReciprocity.neglected.isEmpty)
        #expect(negativeReciprocity.ghosted.isEmpty)
    }

    private func provider(
        over fixture: StowerFixtureDatabase,
        windowDays: Int = 180
    ) -> StowerDebtBoardProvider {
        let url = fixture.databaseURL
        let resolver = contacts
        return StowerDebtBoardProvider(
            readerFactory: {
                try StowerChatDatabaseReader(sourceURL: url, contactsResolver: resolver)
            },
            languageModelJudge: nil,
            cache: nil,
            windowDays: windowDays
        )
    }

    private var contacts: StowerContactsResolver {
        let mapping = ["+14155550100": "Alex", "sam@example.com": "Sam"]
        return StowerContactsResolver(mapping: mapping)
    }
}
