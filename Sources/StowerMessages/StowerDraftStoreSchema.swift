import Foundation
import GRDB

extension StowerDraftStore {
    /// Applies the additive draft-store migrations.
    ///
    /// PRECIOUS posture: migrations are additive and identifiers are append-only —
    /// there is NO `eraseIfStale` and NO `schema_meta` wipe (the disposable
    /// verdict-cache pattern), because erasing precious drafts to "recover" is the
    /// exact data loss this store exists to prevent. A future schema change adds a
    /// NEW migration id; it never renames or reorders an existing one (GRDB tracks
    /// applied ids in its own `grdb_migrations` table, so a rename would re-run the
    /// migration and fail on the already-existing `draft` table).
    internal static func migrate(_ databaseQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("stower-drafts-v1") { database in
            try database.create(table: "draft") { table in
                table.column("draft_key", .text).primaryKey()
                table.column("body", .text).notNull()
                table.column("updated_at", .datetime).notNull()
            }
        }
        try migrator.migrate(databaseQueue)
    }
}
