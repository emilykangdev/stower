import Foundation
import GRDB

extension StowerTriageStore {
    /// Applies the additive triage-store migrations.
    ///
    /// PRECIOUS posture, identical to `StowerDraftStore`: migrations are additive and
    /// identifiers are append-only — there is NO `eraseIfStale` and NO `schema_meta`
    /// wipe (the disposable verdict-cache pattern), because erasing a user's mute or
    /// dismiss intent to "recover" is the exact data loss this store exists to
    /// prevent. A future schema change adds a NEW migration id; it never renames or
    /// reorders an existing one.
    ///
    /// Four tables ship in v1, two current-state and two append-only:
    /// - `dismissed_message` — one row per PERSON (`handleKey` PK). `anchorTimestamp`
    ///   is REQUIRED in v1: the store is precious/append-only, so the strictly-newer
    ///   self-expiry column cannot be added cleanly later.
    /// - `muted_contact` — one row per muted handle (`handleKey` PK), durable.
    /// - `dismissal_history` — append-only; a dismissal MOVES here when a strictly
    ///   newer message retires it (PAR-32 training substrate). No hot-path reader.
    /// - `muted_contact_history` — append-only mute/unmute event log. No reader in v1.
    internal static func migrate(_ databaseQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("stower-triage-v1") { database in
            try database.create(table: "dismissed_message") { table in
                table.column("handleKey", .text).primaryKey()
                table.column("messageGUID", .text).notNull()
                // REAL seconds (timeIntervalSinceReferenceDate), NOT a `.datetime`:
                // GRDB serializes Date to millisecond-precision text, but the live
                // engine timestamp keeps sub-millisecond precision, so a truncated
                // anchor would read as strictly-older than the SAME message on the
                // next load and spuriously self-expire the dismissal. A Double
                // round-trips exactly through SQLite REAL.
                table.column("anchorTimestamp", .double).notNull()
                table.column("dismissedAt", .datetime).notNull()
            }
            try database.create(table: "muted_contact") { table in
                table.column("handleKey", .text).primaryKey()
                table.column("mutedAt", .datetime).notNull()
            }
            try database.create(table: "dismissal_history") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("handleKey", .text).notNull()
                table.column("messageGUID", .text).notNull()
                // REAL seconds, matching `dismissed_message` — the retire MOVE copies
                // the column verbatim, so the archived anchor stays exact too.
                table.column("anchorTimestamp", .double).notNull()
                table.column("dismissedAt", .datetime).notNull()
                table.column("retiredAt", .datetime).notNull()
            }
            try database.create(table: "muted_contact_history") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("handleKey", .text).notNull()
                table.column("event", .text).notNull()  // 'muted' | 'unmuted'
                table.column("at", .datetime).notNull()
            }
        }
        try migrator.migrate(databaseQueue)
    }
}
