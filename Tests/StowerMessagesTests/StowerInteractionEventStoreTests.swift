import Foundation
import GRDB
import Testing

@testable import StowerMessages

/// The precious append-only interaction-event store's invariants (I13): recording
/// the three triage events appends rows with `schemaVersion=1` and the expected
/// fields, `recent(limit:)` returns them newest-first, and a reopen never wipes the
/// log (it is user memory, not a disposable cache).
@Suite("StowerInteractionEventStore")
internal struct StowerInteractionEventStoreTests {
    private static let occurred = Date(timeIntervalSince1970: 1_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-interactions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: I13 — append the three triage events, newest first, with expected fields

    @Test("the three triage events append with expected fields, newest first (I13)")
    internal func recordsThreeEvents() async throws {
        let store = try StowerInteractionEventStore.inMemory()
        try await store.record(
            .messageDismissed(
                handleKey: "e164:14155550100",
                messageGUID: "g1",
                boardTab: "yourTurn",
                occurredAt: Self.occurred
            )
        )
        try await store.record(
            .senderMuted(handleKey: "e164:14155550100", surface: "board", occurredAt: Self.occurred)
        )
        try await store.record(
            .senderUnmuted(
                handleKey: "e164:14155550100",
                surface: "muted_senders",
                occurredAt: Self.occurred
            )
        )

        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 3)
        // Newest first.
        #expect(recent.map(\.eventType) == ["sender_unmuted", "sender_muted", "message_dismissed"])

        let dismissed = try #require(recent.last)
        #expect(dismissed.eventType == StowerInteractionEvent.messageDismissedType)
        #expect(dismissed.handleKey == "e164:14155550100")
        #expect(dismissed.messageGUID == "g1")
        #expect(dismissed.boardTab == "yourTurn")
        #expect(dismissed.surface == "board")
        #expect(dismissed.actor == StowerInteractionEvent.userActor)

        let unmuted = try #require(recent.first)
        #expect(unmuted.surface == "muted_senders")
        #expect(unmuted.messageGUID == nil)
    }

    @Test("recorded rows carry the current schemaVersion (I13)")
    internal func recordsSchemaVersion() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerInteractionEventStore.fileName)

        let store = try StowerInteractionEventStore.open(at: url)
        try await store.record(
            .senderMuted(handleKey: "e164:1", surface: "board", occurredAt: Self.occurred)
        )

        let raw = try DatabaseQueue(path: url.path)
        let version = try await raw.read { database in
            try Int.fetchOne(database, sql: "SELECT schemaVersion FROM interaction_event")
        }
        #expect(version == StowerInteractionEvent.schemaVersion)
    }

    // MARK: I13 — a reopen never wipes the append-only log

    @Test("recorded events survive release and reopen — no wipe (I13)")
    internal func reopenPreservesEvents() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerInteractionEventStore.fileName)

        do {
            let store = try StowerInteractionEventStore.open(at: url)
            try await store.record(
                .messageDismissed(
                    handleKey: "e164:1",
                    messageGUID: "g1",
                    boardTab: "yourTurn",
                    occurredAt: Self.occurred
                )
            )
        }

        let reopened = try StowerInteractionEventStore.open(at: url)
        let recent = try await reopened.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.messageGUID == "g1")
    }

    // MARK: I9 — defaultURL(inFolder:) resolves under Application Support/<folderName>/

    @Test(
        "defaultURL(inFolder:) resolves under Application Support/<folderName>/, events file (I9)"
    )
    internal func defaultURLResolvesUnderGivenFolder() {
        let url = StowerInteractionEventStore.defaultURL(inFolder: "SomeTestFolder")
        #expect(url?.lastPathComponent == StowerInteractionEventStore.fileName)
        #expect(url?.deletingLastPathComponent().lastPathComponent == "SomeTestFolder")
    }

    // MARK: I11 — defaultURL(inFolder:) rejects an unsafe folder name

    @Test("defaultURL(inFolder:) rejects an empty, traversal, or multi-segment folder name (I11)")
    internal func defaultURLRejectsUnsafeFolderNames() {
        #expect(StowerInteractionEventStore.defaultURL(inFolder: "") == nil)
        #expect(StowerInteractionEventStore.defaultURL(inFolder: "../evil") == nil)
        #expect(StowerInteractionEventStore.defaultURL(inFolder: "a/b") == nil)
        #expect(StowerInteractionEventStore.defaultURL(inFolder: "..") == nil)
        #expect(StowerInteractionEventStore.defaultURL(inFolder: ".") == nil)
    }
}
