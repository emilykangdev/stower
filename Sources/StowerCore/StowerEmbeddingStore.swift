import Foundation
import GRDB

/// A vector embedding paired with the item it was computed for.
public struct StowerEmbeddingRecord: Sendable {
    /// The source-namespaced stable item id (`<source>:<native-id>`).
    public let itemID: String

    /// The model fingerprint that produced the vector (`model_id@revision`).
    public let modelID: String

    /// A content hash of the embedded text; a change forces re-embedding.
    public let textHash: String

    /// The embedding, or `nil` when the text was deliberately skipped.
    ///
    /// A skipped row is still recorded so the next index run does not retry it.
    public let vector: [Float]?

    /// Creates an embedding record for one item.
    public init(itemID: String, modelID: String, textHash: String, vector: [Float]?) {
        self.itemID = itemID
        self.modelID = modelID
        self.textHash = textHash
        self.vector = vector
    }
}

/// A cached vector keyed by item id, ready for the semantic arm.
public struct StowerCachedVector: Sendable {
    /// The source-namespaced stable item id.
    public let itemID: String

    /// The L2-normalized embedding.
    public let vector: [Float]
}

/// Errors raised while reading or writing the embedding cache.
public enum StowerEmbeddingStoreError: Error, Sendable, Equatable {
    /// A stored vector BLOB failed validation (wrong byte count or non-finite).
    case corruptVector(itemID: String, detail: String)
}

/// Persistent, model-keyed cache of message embeddings.
///
/// Lives in its own `embeddings.sqlite` so it survives both `StowerIndex`'s
/// per-launch `replaceAll` rebuilds and FTS schema-version erases: the index
/// database is disposable, this cache is precious. Rows are keyed by
/// `(model fingerprint, item id)` with a text hash, so edited or re-modeled
/// content is re-embedded while unchanged content is reused across launches.
public actor StowerEmbeddingStore {
    /// The cache schema version; a mismatch drops only the cache, never the index.
    public static let currentVersion = 1

    /// The file name the store owns inside an index directory.
    public static let fileName = "embeddings.sqlite"

    private let databaseQueue: DatabaseQueue

    /// Opens or creates a file-backed embedding cache at `path`.
    public init(path: String) throws {
        try self.init(path: path, schemaVersion: Self.currentVersion)
    }

    /// Creates an ephemeral in-memory cache for tests and previews.
    public static func inMemory() throws -> StowerEmbeddingStore {
        try StowerEmbeddingStore(databaseQueue: DatabaseQueue(), schemaVersion: currentVersion)
    }

    /// Opens a file-backed cache, declaring the schema version to honor.
    ///
    /// Tests pass a bumped version to exercise the cache-drop path.
    internal init(path: String, schemaVersion: Int) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        try self.init(
            databaseQueue: DatabaseQueue(path: path, configuration: configuration),
            schemaVersion: schemaVersion
        )
    }

    private init(databaseQueue: DatabaseQueue, schemaVersion: Int) throws {
        try Self.prepare(databaseQueue, schemaVersion: schemaVersion)
        self.databaseQueue = databaseQueue
    }

    /// Returns `[item id: text hash]` for every row stored under `fingerprint`.
    public func existingHashes(fingerprint: String) throws -> [String: String] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT item_id, text_hash FROM embedding WHERE model_id = ?",
                arguments: [fingerprint]
            )
            return rows.reduce(into: [String: String]()) { result, row in
                result[row["item_id"]] = row["text_hash"]
            }
        }
    }

    /// Persists one batch of records in a single transaction.
    ///
    /// Per-batch commits make a first index resumable: an interrupt after batch
    /// `k` leaves `k` batches durably stored, and the next run embeds only the rest.
    public func upsert(_ records: [StowerEmbeddingRecord]) throws {
        guard !records.isEmpty else { return }
        try databaseQueue.write { database in
            for record in records {
                try Self.insert(record, into: database)
            }
        }
    }

    /// Returns every stored vector for `fingerprint`, skipping skipped rows.
    public func vectors(fingerprint: String) throws -> [StowerCachedVector] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT item_id, vector, dims FROM embedding
                    WHERE model_id = ? AND vector IS NOT NULL
                    """,
                arguments: [fingerprint]
            )
            return try rows.map { row in
                let itemID: String = row["item_id"]
                let vectorBlob: Data = row["vector"]
                let dims: Int = row["dims"]
                return StowerCachedVector(
                    itemID: itemID,
                    vector: try Self.decodeVector(vectorBlob, dims: dims, itemID: itemID)
                )
            }
        }
    }

    /// Deletes cached rows whose item id is not in `keepingItemIDs`.
    ///
    /// Bounds cache growth after a shrinking window without touching survivors.
    public func prune(keepingItemIDs: Set<String>) throws {
        try databaseQueue.write { database in
            let stored = try String.fetchAll(
                database,
                sql: "SELECT DISTINCT item_id FROM embedding"
            )
            let orphans = stored.filter { !keepingItemIDs.contains($0) }
            for chunk in stride(from: 0, to: orphans.count, by: 500).map({ start in
                Array(orphans[start..<min(start + 500, orphans.count)])
            }) {
                let placeholders = databaseQuestionMarks(chunk.count)
                try database.execute(
                    sql: "DELETE FROM embedding WHERE item_id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    private static func insert(_ record: StowerEmbeddingRecord, into database: Database) throws {
        let dims = record.vector?.count ?? 0
        let blob = try record.vector.map { try encodeNormalized($0, itemID: record.itemID) }
        try database.execute(
            sql: """
                INSERT INTO embedding (item_id, model_id, text_hash, vector, dims)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(model_id, item_id) DO UPDATE SET
                    text_hash = excluded.text_hash,
                    vector = excluded.vector,
                    dims = excluded.dims
                """,
            arguments: [record.itemID, record.modelID, record.textHash, blob, dims]
        )
    }
}

private func databaseQuestionMarks(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
