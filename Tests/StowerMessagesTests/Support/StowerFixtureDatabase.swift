import Foundation
import GRDB

internal struct StowerFixtureDatabase {
    internal static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    internal let rootURL: URL
    internal let databaseURL: URL

    internal init() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stower-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        databaseURL = rootURL.appendingPathComponent("chat.db")
        try Self.populate(databaseURL)
    }

    internal func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func populate(_ databaseURL: URL) throws {
        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try databaseQueue.write { database in
            try createSchema(database)
            try insertHandlesAndChats(database)
            try insertMessages(database)
        }
    }

    private static func createSchema(_ database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE message (
                  guid TEXT NOT NULL,
                  text TEXT,
                  attributedBody BLOB,
                  date INTEGER NOT NULL,
                  is_from_me INTEGER NOT NULL,
                  handle_id INTEGER NOT NULL,
                  associated_message_type INTEGER NOT NULL,
                  item_type INTEGER NOT NULL,
                  cache_has_attachments INTEGER NOT NULL,
                  balloon_bundle_id TEXT
                );
                CREATE TABLE handle (id TEXT NOT NULL);
                CREATE TABLE chat (
                  guid TEXT,
                  chat_identifier TEXT NOT NULL,
                  display_name TEXT,
                  style INTEGER NOT NULL
                );
                CREATE TABLE chat_message_join (
                  chat_id INTEGER NOT NULL,
                  message_id INTEGER NOT NULL
                );
                CREATE TABLE chat_handle_join (
                  chat_id INTEGER NOT NULL,
                  handle_id INTEGER NOT NULL
                );
                """
        )
    }

    private static func insertHandlesAndChats(_ database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO handle (ROWID, id) VALUES
                  (1, '+14155550100'),
                  (2, 'sam@example.com');
                INSERT INTO chat (ROWID, guid, chat_identifier, display_name, style) VALUES
                  (1, 'chat-alex', '+14155550100', NULL, 45),
                  (2, 'chat-group', 'group-identifier', 'Project Group', 43);
                INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                  (1, 1),
                  (2, 1),
                  (2, 2);
                """
        )
    }

    private static func insertMessages(_ database: Database) throws {
        let recentBody = try archive(NSAttributedString(string: "incoming NS Attribute"))
        var values = primaryMessages(recentBody: recentBody)
        values.append(contentsOf: filteredMessages())
        values.append(contentsOf: newestMessages())
        for (offset, value) in values.enumerated() {
            let rowID = Int64(offset + 1)
            try insertMessage(database, rowID: rowID, value: value)
            try database.execute(
                sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
                arguments: [value.chatID, rowID]
            )
            if value.id == "duplicate" {
                try database.execute(
                    sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
                    arguments: [2, rowID]
                )
            }
        }
    }

    private static func primaryMessages(recentBody: Data) -> [FixtureMessage] {
        var values: [FixtureMessage] = []
        values.append(
            FixtureMessage(id: "old", text: "older than window", date: rawDate(daysAgo: 200))
        )
        values.append(FixtureMessage(id: "incoming", body: recentBody, date: rawDate(daysAgo: 10)))
        values.append(
            FixtureMessage(
                id: "outgoing",
                text: "outgoing text",
                date: rawDate(daysAgo: 9),
                isFromMe: true,
                handleID: 0
            )
        )
        values.append(
            FixtureMessage(id: "duplicate", text: "one indexed copy", date: rawDate(daysAgo: 7))
        )
        values.append(
            FixtureMessage(
                id: "group-incoming",
                text: "group response",
                date: rawDate(daysAgo: 6),
                handleID: 2,
                chatID: 2
            )
        )
        return values
    }

    private static func filteredMessages() -> [FixtureMessage] {
        var values: [FixtureMessage] = []
        values.append(
            FixtureMessage(
                id: "tapback",
                text: "Liked a message",
                date: rawDate(daysAgo: 8),
                associatedType: 2000
            )
        )
        values.append(
            FixtureMessage(
                id: "system",
                text: "Renamed chat",
                date: rawDate(daysAgo: 8),
                itemType: 1
            )
        )
        values.append(
            FixtureMessage(id: "attachment", date: rawDate(daysAgo: 8), hasAttachments: true)
        )
        values.append(
            FixtureMessage(id: "balloon", date: rawDate(daysAgo: 8), balloonID: "fixture.app")
        )
        values.append(FixtureMessage(id: "zero", text: "invalid date", date: 0))
        return values
    }

    private static func newestMessages() -> [FixtureMessage] {
        var values: [FixtureMessage] = []
        values.append(
            FixtureMessage(id: "tie-a", text: "same timestamp a", date: rawDate(daysAgo: 2))
        )
        values.append(
            FixtureMessage(
                id: "tie-b",
                text: "same timestamp b",
                date: rawDate(daysAgo: 2),
                isFromMe: true,
                handleID: 0
            )
        )
        values.append(
            FixtureMessage(id: "newest", text: "newest message", date: rawDate(daysAgo: 1))
        )
        return values
    }

    private static func insertMessage(
        _ database: Database,
        rowID: Int64,
        value: FixtureMessage
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO message (
                  ROWID, guid, text, attributedBody, date, is_from_me, handle_id,
                  associated_message_type, item_type, cache_has_attachments, balloon_bundle_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: messageArguments(rowID: rowID, value: value)
        )
    }

    private static func messageArguments(
        rowID: Int64,
        value: FixtureMessage
    ) -> StatementArguments {
        var values: [DatabaseValueConvertible?] = []
        values.append(rowID)
        values.append(value.id)
        values.append(value.text)
        values.append(value.body)
        values.append(value.date)
        values.append(value.isFromMe)
        values.append(value.handleID)
        values.append(value.associatedType)
        values.append(value.itemType)
        values.append(value.hasAttachments)
        values.append(value.balloonID)
        return StatementArguments(values)
    }

    private static func rawDate(daysAgo: Int) -> Int64 {
        let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    private static func archive(_ value: Any) throws -> Data {
        let selector = NSSelectorFromString("archivedDataWithRootObject:")
        guard let archiver = NSClassFromString("NSArchiver") as? NSObject.Type,
            let result = archiver.perform(selector, with: value),
            let data = result.takeUnretainedValue() as? Data
        else {
            throw FixtureError.archiveFailed
        }
        return data
    }
}

private enum FixtureError: Error {
    case archiveFailed
}

private struct FixtureMessage {
    fileprivate let id: String
    fileprivate var text: String?
    fileprivate var body: Data?
    fileprivate let date: Int64
    fileprivate var isFromMe = false
    fileprivate var handleID: Int64 = 1
    fileprivate var associatedType: Int64 = 0
    fileprivate var itemType: Int64 = 0
    fileprivate var hasAttachments = false
    fileprivate var balloonID: String?
    fileprivate var chatID: Int64 = 1
}
