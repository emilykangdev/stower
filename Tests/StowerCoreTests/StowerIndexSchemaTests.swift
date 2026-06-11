import Foundation
import GRDB
import Testing

@testable import StowerCore

@Suite("StowerIndexSchema")
internal struct StowerIndexSchemaTests {
    @Test("creates the item, FTS, and metadata tables")
    internal func createsExpectedSchema() async throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        _ = try StowerIndex(path: fixture.databaseURL.path)
        let databaseQueue = try DatabaseQueue(path: fixture.databaseURL.path)

        let tables = try await databaseQueue.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
            )
        }
        let columns = try await databaseQueue.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM pragma_table_info('item_fts')")
        }

        #expect(Set(tables).isSuperset(of: ["meta", "item", "item_fts"]))
        #expect(columns == ["text", "group_title"])
    }

    @Test("erases content when the stored schema version is stale")
    internal func erasesStaleSchema() async throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        let databaseQueue = try DatabaseQueue(path: fixture.databaseURL.path)
        try await databaseQueue.write { database in
            try database.execute(
                sql: """
                    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    INSERT INTO meta (key, value) VALUES ('schema_version', '999');
                    CREATE TABLE obsolete (value TEXT);
                    INSERT INTO obsolete (value) VALUES ('stale');
                    """
            )
        }

        let index = try StowerIndex(path: fixture.databaseURL.path)

        #expect(try await index.search("stale").isEmpty)
        let obsoleteExists = try await databaseQueue.read { database in
            try database.tableExists("obsolete")
        }
        #expect(!obsoleteExists)
    }

    @Test("external-content FTS integrity check passes after replacement")
    internal func externalContentIntegrity() async throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        let index = try StowerIndex(path: fixture.databaseURL.path)
        try await index.ingest([SchemaTestItem(id: "one", text: "first")])
        try await index.ingest([SchemaTestItem(id: "one", text: "second")])
        let databaseQueue = try DatabaseQueue(path: fixture.databaseURL.path)

        try await databaseQueue.write { database in
            try database.execute(
                sql: "INSERT INTO item_fts(item_fts, rank) VALUES ('integrity-check', 1)"
            )
        }

        #expect(try await index.search("second").count == 1)
    }
}

private struct IndexFixture {
    fileprivate let rootURL: URL
    fileprivate let databaseURL: URL

    fileprivate init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stower-index-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        databaseURL = rootURL.appendingPathComponent("index.sqlite")
    }

    fileprivate func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct SchemaTestItem: StowerIndexedItem {
    fileprivate let id: String
    fileprivate let text: String
    fileprivate let source = StowerSource.messages
    fileprivate let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    fileprivate let metadata: [String: String] = [:]
    fileprivate let deepLink: URL? = nil
    fileprivate let groupID = "group"
    fileprivate let groupTitle = "Title"
}
