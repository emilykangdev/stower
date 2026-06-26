import Foundation
import GRDB

extension StowerInteractionEventStore {
    /// Applies the additive interaction-event-store migrations.
    ///
    /// PRECIOUS append-only posture, identical to `StowerDraftStore`: migrations are
    /// additive and append-only — NO `eraseIfStale`, NO `schema_meta` wipe. The event
    /// log is the user's own interaction memory; treating it like a disposable cache
    /// and wiping on a version bump is the exact data loss this store prevents. A
    /// future event type adds NO column — `eventType` is a string token and extra
    /// fields ride in `metadataJSON` — so v1 is one append-only table.
    internal static func migrate(_ databaseQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("stower-interactions-v1") { database in
            try database.create(table: "interaction_event") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("eventType", .text).notNull()
                table.column("occurredAt", .datetime).notNull()
                table.column("actor", .text).notNull()
                table.column("surface", .text).notNull()
                table.column("handleKey", .text)
                table.column("messageGUID", .text)
                table.column("draftKey", .text)
                table.column("boardTab", .text)
                table.column("metadataJSON", .text).notNull().defaults(to: "{}")
                table.column("schemaVersion", .integer).notNull()
            }
        }
        try migrator.migrate(databaseQueue)
    }
}
