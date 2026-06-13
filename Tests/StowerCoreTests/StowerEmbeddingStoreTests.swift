import Foundation
import GRDB
import Testing

@testable import StowerCore

@Suite("StowerEmbeddingStore")
internal struct StowerEmbeddingStoreTests {
    @Test("embedding rows survive an index replaceAll")
    internal func survivesReplaceAll() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StowerEmbeddingStore(path: storePath(directory))
        let index = try StowerIndex(path: indexPath(directory))
        try await store.upsert([record(id: "messages:one", vector: [1, 0, 0, 0])])

        try await index.replaceAll(with: [StowerTestItem(id: "one", text: "hello")])

        #expect(try await store.vectors(fingerprint: Self.fingerprint).count == 1)
    }

    @Test("embedding cache survives an FTS schema-version erase")
    internal func survivesFTSSchemaBump() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StowerEmbeddingStore(path: storePath(directory))
        try await store.upsert([record(id: "messages:one", vector: [1, 0, 0, 0])])
        _ = try StowerIndex(path: indexPath(directory))

        try bumpIndexSchemaVersion(at: indexPath(directory))
        _ = try StowerIndex(path: indexPath(directory))  // re-open triggers eraseIfStale

        #expect(try await store.vectors(fingerprint: Self.fingerprint).count == 1)
    }

    @Test("a cache version bump drops only embeddings, leaving the index file")
    internal func versionBumpDropsOnlyCache() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try StowerIndex(path: indexPath(directory))
        try await index.replaceAll(with: [StowerTestItem(id: "one", text: "kept")])
        let store = try StowerEmbeddingStore(path: storePath(directory))
        try await store.upsert([record(id: "messages:one", vector: [1, 0, 0, 0])])

        let bumped = try StowerEmbeddingStore(path: storePath(directory), schemaVersion: 999)

        #expect(try await bumped.vectors(fingerprint: Self.fingerprint).isEmpty)
        #expect(try await index.search("kept").map(\.item.id) == ["messages:one"])
    }

    @Test("a corrupt vector BLOB throws a named error rather than trapping")
    internal func corruptBlobThrows() throws {
        #expect(throws: StowerEmbeddingStoreError.self) {
            _ = try StowerEmbeddingStore.decodeVector(Data([1, 2, 3]), dims: 1, itemID: "x")
        }
        var notANumber = Float.nan
        let nanData = withUnsafeBytes(of: &notANumber) { Data($0) }
        #expect(throws: StowerEmbeddingStoreError.self) {
            _ = try StowerEmbeddingStore.decodeVector(nanData, dims: 1, itemID: "x")
        }
    }

    @Test("each batch commits independently so an interrupted index resumes")
    internal func perBatchCommitPersists() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StowerEmbeddingStore(path: storePath(directory))
        try await store.upsert([record(id: "messages:1", vector: [1, 0, 0, 0])])
        try await store.upsert([record(id: "messages:2", vector: [0, 1, 0, 0])])

        let reopened = try StowerEmbeddingStore(path: storePath(directory))

        #expect(try await reopened.existingHashes(fingerprint: Self.fingerprint).count == 2)
    }

    @Test("cache key is (model, item, text-hash): models do not collide, text changes show")
    internal func cacheKeyIsModelItemHash() async throws {
        let store = try StowerEmbeddingStore.inMemory()
        try await store.upsert([
            record(id: "messages:1", modelID: "a@v1", hash: "x", vector: [1, 0, 0, 0])
        ])
        try await store.upsert([
            record(id: "messages:1", modelID: "b@v1", hash: "y", vector: [0, 1, 0, 0])
        ])

        #expect(try await store.existingHashes(fingerprint: "a@v1") == ["messages:1": "x"])
        #expect(try await store.existingHashes(fingerprint: "b@v1") == ["messages:1": "y"])
        #expect(try await store.vectors(fingerprint: "a@v1").count == 1)
        #expect(try await store.vectors(fingerprint: "b@v1").count == 1)
    }

    @Test("skipped rows are recorded but yield no vector")
    internal func skippedRowsRecorded() async throws {
        let store = try StowerEmbeddingStore.inMemory()
        try await store.upsert([record(id: "messages:1", hash: "x", vector: nil)])

        #expect(
            try await store.existingHashes(fingerprint: Self.fingerprint) == ["messages:1": "x"]
        )
        #expect(try await store.vectors(fingerprint: Self.fingerprint).isEmpty)
    }

    @Test("vectors are L2-normalized at write so dot product equals cosine")
    internal func vectorsNormalizedAtWrite() async throws {
        let store = try StowerEmbeddingStore.inMemory()
        try await store.upsert([record(id: "messages:1", vector: [3, 4, 0, 0])])

        let stored = try #require(try await store.vectors(fingerprint: Self.fingerprint).first)
        let norm = (stored.vector.reduce(into: Float(0)) { $0 += $1 * $1 }).squareRoot()
        #expect(abs(norm - 1) < 1e-5)
        #expect(abs(stored.vector[0] - 0.6) < 1e-5)
        #expect(abs(stored.vector[1] - 0.8) < 1e-5)
    }

    @Test("prune removes only orphan ids")
    internal func pruneRemovesOnlyOrphans() async throws {
        let store = try StowerEmbeddingStore.inMemory()
        var records: [StowerEmbeddingRecord] = []
        records.append(record(id: "messages:1", vector: [1, 0, 0, 0]))
        records.append(record(id: "messages:2", vector: [0, 1, 0, 0]))
        records.append(record(id: "messages:3", vector: [0, 0, 1, 0]))
        try await store.upsert(records)

        try await store.prune(keepingItemIDs: ["messages:1", "messages:3"])

        let ids = try await store.vectors(fingerprint: Self.fingerprint).map(\.itemID).sorted()
        #expect(ids == ["messages:1", "messages:3"])
    }

    // MARK: - Fixtures

    private static let fingerprint = "fake-model@v1"

    private func record(
        id: String,
        modelID: String = StowerEmbeddingStoreTests.fingerprint,
        hash: String = "hash",
        vector: [Float]?
    ) -> StowerEmbeddingRecord {
        StowerEmbeddingRecord(itemID: id, modelID: modelID, textHash: hash, vector: vector)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-store-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storePath(_ directory: URL) -> String {
        directory.appendingPathComponent(StowerEmbeddingStore.fileName).path
    }

    private func indexPath(_ directory: URL) -> String {
        directory.appendingPathComponent("index.sqlite").path
    }

    private func bumpIndexSchemaVersion(at path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { database in
            try database.execute(
                sql: "UPDATE meta SET value = ? WHERE key = ?",
                arguments: ["999", "schema_version"]
            )
        }
        try queue.close()
    }
}
