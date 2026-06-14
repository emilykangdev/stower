import Foundation
import GRDB

internal struct StowerFixtureDatabase {
    internal static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    internal let rootURL: URL
    internal let databaseURL: URL

    /// Kept open for WAL fixtures so frames stay in the sidecar file,
    /// matching a live Messages.app database.
    private let retainedQueue: DatabaseQueue?

    internal init(useWriteAheadLog: Bool = false) throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stower-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        databaseURL = rootURL.appendingPathComponent("chat.db")
        retainedQueue = try Self.populate(databaseURL, useWriteAheadLog: useWriteAheadLog)
    }

    internal func remove() {
        try? retainedQueue?.close()
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func populate(
        _ databaseURL: URL,
        useWriteAheadLog: Bool
    ) throws -> DatabaseQueue? {
        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        if useWriteAheadLog {
            try databaseQueue.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA journal_mode=WAL")
            }
        }
        try databaseQueue.write { database in
            try createSchema(database)
            try insertHandlesAndChats(database)
            try insertMessages(database)
        }
        return useWriteAheadLog ? databaseQueue : nil
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
                  associated_message_guid TEXT,
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
        try insertHandles(database)
        try insertChats(database)
        try insertChatHandleJoins(database)
    }

    private static func insertHandles(_ database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO handle (ROWID, id) VALUES
                  (1, '+14155550100'), (2, 'sam@example.com'), (3, '+14155550299'),
                  (4, '+14155550300'), (5, 'od#d@example.com'), (6, '+14155550601'),
                  (7, '+14155550602'), (8, '+14155550603'), (9, '+14155550604'),
                  (10, '+14155550605'), (11, '+14155550606'), (12, '+14155550607'),
                  (13, '+14155550608'), (14, '+14155550609');
                """
        )
    }

    private static func insertChats(_ database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO chat (ROWID, guid, chat_identifier, display_name, style) VALUES
                  (1, 'chat-alex', '+14155550100', NULL, 45),
                  (2, 'chat-group', 'group-identifier', 'Project Group', 43),
                  (3, 'chat-bea', '+14155550300', NULL, 45),
                  (4, 'chat-reserved', 'od#d@example.com', NULL, 45),
                  (5, 'chat-clears', '+14155550601', NULL, 45),
                  (6, 'chat-removed', '+14155550602', NULL, 45),
                  (7, 'chat-oldreact', '+14155550603', NULL, 45),
                  (8, 'chat-attach-react', '+14155550604', NULL, 45),
                  (9, 'chat-prefixed', '+14155550605', NULL, 45),
                  (10, 'chat-outbound-attach', '+14155550606', NULL, 45),
                  (11, 'chat-inbound-photo', '+14155550607', NULL, 45),
                  (12, 'chat-system', '+14155550608', NULL, 45),
                  (13, 'chat-stale', '+14155550609', NULL, 45);
                """
        )
    }

    private static func insertChatHandleJoins(_ database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                  (1, 1), (2, 1), (2, 2), (3, 3), (3, 4), (4, 5), (5, 6), (6, 7),
                  (7, 8), (8, 9), (9, 10), (10, 11), (11, 12), (12, 13), (13, 14);
                """
        )
    }

    private static func insertMessages(_ database: Database) throws {
        let recentBody = try archive(NSAttributedString(string: "incoming NS Attribute"))
        var values = primaryMessages(recentBody: recentBody)
        values.append(contentsOf: filteredMessages())
        values.append(contentsOf: newestMessages())
        values.append(contentsOf: deepLinkMessages())
        values.append(contentsOf: reactionScenarios())
        values.append(contentsOf: chronologyScenarios())
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

    private static func insertMessage(
        _ database: Database,
        rowID: Int64,
        value: FixtureMessage
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO message (
                  ROWID, guid, text, attributedBody, date, is_from_me, handle_id,
                  associated_message_type, associated_message_guid, item_type,
                  cache_has_attachments, balloon_bundle_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        values.append(value.associatedGuid)
        values.append(value.itemType)
        values.append(value.hasAttachments)
        values.append(value.balloonID)
        return StatementArguments(values)
    }

    internal static func rawDate(daysAgo: Int) -> Int64 {
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

// MARK: - Message fixtures

extension StowerFixtureDatabase {
    fileprivate static func primaryMessages(recentBody: Data) -> [FixtureMessage] {
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
        values.append(
            FixtureMessage(
                id: "link",
                text: "https://example.com/article",
                date: rawDate(daysAgo: 5),
                balloonID: "com.apple.messages.URLBalloonProvider"
            )
        )
        return values
    }

    fileprivate static func filteredMessages() -> [FixtureMessage] {
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
            FixtureMessage(
                id: "balloon",
                text: "app payload text",
                date: rawDate(daysAgo: 8),
                balloonID: "fixture.app"
            )
        )
        values.append(FixtureMessage(id: "zero", text: "invalid date", date: 0))
        return values
    }

    fileprivate static func newestMessages() -> [FixtureMessage] {
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

    /// A 1:1 chat whose join row holds TWO handles (old + current number);
    /// the deep link must follow chat_identifier, not the first handle.
    ///
    /// Also covers an email identifier carrying a reserved URL character,
    /// which must be percent-encoded in the deep link.
    fileprivate static func deepLinkMessages() -> [FixtureMessage] {
        var values: [FixtureMessage] = []
        values.append(
            FixtureMessage(
                id: "bea-incoming",
                text: "hello from the current number",
                date: rawDate(daysAgo: 4),
                handleID: 4,
                chatID: 3
            )
        )
        values.append(
            FixtureMessage(
                id: "reserved-incoming",
                text: "hello from a reserved-char email",
                date: rawDate(daysAgo: 3),
                handleID: 5,
                chatID: 4
            )
        )
        return values
    }
}

private enum FixtureError: Error {
    case archiveFailed
}

internal struct FixtureMessage {
    internal let id: String
    internal var text: String?
    internal var body: Data?
    internal let date: Int64
    internal var isFromMe = false
    internal var handleID: Int64 = 1
    internal var associatedType: Int64 = 0
    internal var associatedGuid: String?
    internal var itemType: Int64 = 0
    internal var hasAttachments = false
    internal var balloonID: String?
    internal var chatID: Int64 = 1
}
