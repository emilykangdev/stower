import Foundation
import GRDB

extension StowerEmbeddingStore {
    /// Prepares the cache schema, dropping all rows on a version mismatch.
    ///
    /// The drop is scoped to this file only; the index database is a separate
    /// file and is never touched by a cache version bump.
    internal static func prepare(_ databaseQueue: DatabaseQueue, schemaVersion: Int) throws {
        try eraseIfStale(databaseQueue, schemaVersion: schemaVersion)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("stower-embeddings-v1") { database in
            try database.create(table: "schema_meta") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
            try database.create(table: "embedding") { table in
                table.column("item_id", .text).notNull()
                table.column("model_id", .text).notNull()
                table.column("text_hash", .text).notNull()
                table.column("vector", .blob)
                table.column("dims", .integer).notNull()
                table.primaryKey(["model_id", "item_id"])
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

    /// L2-normalizes a vector and encodes it as a host-endian Float32 BLOB.
    ///
    /// Normalizing at write makes the retriever's dot product equal cosine
    /// similarity regardless of what the embedder returned. The store is always
    /// local on little-endian Apple hardware, so host-endian bytes are portable
    /// enough; cross-endian transport is a non-goal.
    internal static func encodeNormalized(_ vector: [Float], itemID: String) throws -> Data {
        let norm = sqrt(vector.reduce(into: Float(0)) { $0 += $1 * $1 })
        guard norm.isFinite, norm > 0 else {
            throw StowerEmbeddingStoreError.corruptVector(
                itemID: itemID,
                detail: "vector has zero or non-finite L2 norm"
            )
        }
        let normalized = vector.map { $0 / norm }
        return normalized.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decodes a Float32 BLOB, validating byte count and finiteness.
    ///
    /// Reads with `loadUnaligned`: a `Data` slice is not guaranteed to be
    /// 4-byte aligned, and `load(as:)` on an unaligned address traps.
    internal static func decodeVector(_ data: Data, dims: Int, itemID: String) throws -> [Float] {
        guard dims > 0, data.count == dims * MemoryLayout<Float>.size else {
            throw StowerEmbeddingStoreError.corruptVector(
                itemID: itemID,
                detail: "expected \(dims * 4) bytes, found \(data.count)"
            )
        }
        let vector: [Float] = data.withUnsafeBytes { raw in
            (0..<dims).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw StowerEmbeddingStoreError.corruptVector(
                itemID: itemID,
                detail: "vector contains a non-finite value"
            )
        }
        return vector
    }
}
