import Foundation
import GRDB
import Testing

@testable import StowerMessages

/// The `resolved_at` additive migration's effect on pre-existing rows (I5).
///
/// Builds a TRUE v1-only fixture — a test-only migrator registering ONLY
/// `stower-drafts-v1` — so opening it with the real store proves the v1→v2 path,
/// not just that a v2 DB round-trips (a v2-created fixture would prove nothing
/// about migrating existing installs).
@Suite("StowerDraftStoreSchema")
internal struct StowerDraftStoreSchemaTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-drafts-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: I5 — a pre-migration row reads as active after the v2 bump

    @Test("a v1-only row migrates to v2 with resolved_at = NULL (I5)")
    internal func v1RowMigratesToActiveV2() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(StowerDraftStore.fileName).path

        // Build a genuine v1-only database: register ONLY the v1 migration, so
        // the file never sees `resolved_at` until the real store opens it.
        var v1Migrator = DatabaseMigrator()
        v1Migrator.registerMigration("stower-drafts-v1") { database in
            try database.create(table: "draft") { table in
                table.column("draft_key", .text).primaryKey()
                table.column("body", .text).notNull()
                table.column("updated_at", .datetime).notNull()
            }
        }
        let v1Queue = try DatabaseQueue(path: path)
        try v1Migrator.migrate(v1Queue)
        try await v1Queue.write { database in
            try database.execute(
                sql: "INSERT INTO draft (draft_key, body, updated_at) VALUES (?, ?, ?)",
                arguments: ["raw:pre-migration", "already here", Date()]
            )
        }

        // Opening with the real store applies the v2 migration on top of v1.
        let migrated = try StowerDraftStore(path: path)
        let record = try await migrated.all()["raw:pre-migration"]
        #expect(record?.body == "already here")
        #expect(record?.resolvedAt == nil)
    }
}
