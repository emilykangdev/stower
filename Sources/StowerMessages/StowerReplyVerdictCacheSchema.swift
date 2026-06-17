import Foundation
import GRDB

extension StowerReplyVerdictCache {
    /// Prepares the cache schema, dropping all rows on a version mismatch.
    ///
    /// The cache is disposable: a version bump erases it and the next refresh
    /// refills it. Nothing else depends on these rows, so the drop is safe.
    internal static func prepare(_ databaseQueue: DatabaseQueue, schemaVersion: Int) throws {
        try eraseIfStale(databaseQueue, schemaVersion: schemaVersion)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("stower-reply-verdicts-v1") { database in
            try database.create(table: "schema_meta") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
            try database.create(table: "verdict") { table in
                table.column("judge_version", .text).notNull()
                table.column("message_guid", .text).notNull()
                table.column("input_hash", .text).notNull()
                table.column("expects_reply", .boolean).notNull()
                table.column("confidence", .double).notNull()
                table.column("verdict_source", .text).notNull()
                table.primaryKey(["judge_version", "message_guid"])
            }
            try database.execute(
                sql: "INSERT INTO schema_meta (key, value) VALUES (?, ?)",
                arguments: ["schema_version", String(schemaVersion)]
            )
        }
        try migrator.migrate(databaseQueue)
    }

    private static func eraseIfStale(_ databaseQueue: DatabaseQueue, schemaVersion: Int) throws {
        let storedVersion: String? = try databaseQueue.read { database in
            guard try database.tableExists("schema_meta") else { return nil }
            return try String.fetchOne(
                database,
                sql: "SELECT value FROM schema_meta WHERE key = ?",
                arguments: ["schema_version"]
            )
        }
        guard let storedVersion, storedVersion != String(schemaVersion) else { return }
        try databaseQueue.erase()
    }
}
