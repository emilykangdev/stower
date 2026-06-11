import GRDB

internal enum StowerIndexSchema {
    internal static let currentVersion = 1

    internal static func prepare(_ databaseQueue: DatabaseQueue) throws {
        try eraseIfStale(databaseQueue)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("stower-index-v1") { database in
            try createMeta(in: database)
            try createItems(in: database)
            try createFullTextIndex(in: database)
            try database.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
                arguments: ["schema_version", String(currentVersion)]
            )
        }
        try migrator.migrate(databaseQueue)
    }

    private static func eraseIfStale(_ databaseQueue: DatabaseQueue) throws {
        let storedVersion: String? = try databaseQueue.read { database in
            guard try database.tableExists("meta") else {
                return nil
            }
            return try String.fetchOne(
                database,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: ["schema_version"]
            )
        }
        guard let storedVersion, storedVersion != String(currentVersion) else {
            return
        }
        try databaseQueue.erase()
    }

    private static func createMeta(in database: Database) throws {
        try database.create(table: "meta") { table in
            table.column("key", .text).primaryKey()
            table.column("value", .text).notNull()
        }
    }

    private static func createItems(in database: Database) throws {
        try database.create(table: "item") { table in
            table.column("id", .text).primaryKey()
            table.column("source", .text).notNull()
            table.column("text", .text).notNull()
            table.column("timestamp", .double).notNull()
            table.column("deep_link", .text)
            table.column("group_id", .text).notNull()
            table.column("group_title", .text).notNull()
            table.column("metadata", .text).notNull()
        }
    }

    private static func createFullTextIndex(in database: Database) throws {
        try database.create(virtualTable: "item_fts", using: FTS5()) { table in
            table.content = "item"
            table.contentRowID = "rowid"
            table.tokenizer = .porter(wrapping: .unicode61())
            table.column("text")
            table.column("group_title")
        }
    }
}
