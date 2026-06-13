import Foundation
import Testing

@testable import StowerCore

@Suite("StowerRetriever")
internal struct StowerRetrieverTests {
    @Test("zero cached vectors falls back to FTS-only without an embed call")
    internal func zeroVectorsIsFTSOnly() async throws {
        let index = try StowerIndex.inMemory()
        try await index.replaceAll(with: [StowerTestItem(id: "a", text: "pizza tonight")])
        let embedder = StowerFakeEmbedder(dims: 4, vectorsByText: [:])
        let store = try StowerEmbeddingStore.inMemory()
        let retriever = StowerRetriever(index: index, store: store, embedder: embedder)

        let arms = try await retriever.evaluate("pizza")

        #expect(arms.semantic.isEmpty)
        #expect(arms.hybrid.map(\.item.id) == arms.fts.map(\.item.id))
        #expect(arms.hybrid.map(\.item.id) == ["messages:a"])
        #expect(await embedder.embeddedQueryForms.isEmpty)
    }

    @Test("hybrid surfaces a semantic-only hit that shares zero query tokens")
    internal func hybridSurfacesSemanticOnly() async throws {
        var items: [StowerTestItem] = []
        items.append(StowerTestItem(id: "a", text: "pizza margherita downtown"))
        items.append(StowerTestItem(id: "b", text: "the quarterly budget figures"))
        var vectors: [String: [Float]] = [:]
        vectors["pizza margherita downtown"] = [1, 0, 0, 0]
        vectors["the quarterly budget figures"] = [0, 1, 0, 0]
        vectors["dinner plans tonight"] = [0, 1, 0, 0]
        let context = try await makeRetriever(items: items, vectorsByText: vectors)

        let arms = try await context.retriever.evaluate("dinner plans tonight")

        #expect(arms.fts.isEmpty)
        #expect(arms.hybrid.contains { $0.item.id == "messages:b" })
    }

    @Test("hybrid surfaces an FTS-only hit the semantic arm ranks low")
    internal func hybridSurfacesFTSOnly() async throws {
        var items: [StowerTestItem] = []
        items.append(StowerTestItem(id: "a", text: "pizza tonight"))
        items.append(StowerTestItem(id: "b", text: "budget review"))
        var vectors: [String: [Float]] = [:]
        vectors["pizza tonight"] = [1, 0, 0, 0]
        vectors["budget review"] = [0, 1, 0, 0]
        vectors["pizza"] = [0, 1, 0, 0]
        let context = try await makeRetriever(items: items, vectorsByText: vectors)

        let arms = try await context.retriever.evaluate("pizza")

        #expect(arms.hybrid.contains { $0.item.id == "messages:a" })
    }

    @Test("fusion is deterministic and ties break by timestamp then id")
    internal func fusionIsDeterministicAndOrderStable() async throws {
        // "alpha keyword" has no fixture vector, so it is FTS-only; the query
        // vector matches y, so y is semantic-only. Both land at fused rank 0.
        var items: [StowerTestItem] = []
        items.append(StowerTestItem(id: "x", text: "alpha keyword", timestamp: instant(100)))
        items.append(StowerTestItem(id: "y", text: "beta term", timestamp: instant(200)))
        var vectors: [String: [Float]] = [:]
        vectors["beta term"] = [0, 1, 0, 0]
        vectors["alpha"] = [0, 1, 0, 0]
        let context = try await makeRetriever(items: items, vectorsByText: vectors)

        let first = try await context.retriever.evaluate("alpha").hybrid.map(\.item.id)
        let second = try await context.retriever.evaluate("alpha").hybrid.map(\.item.id)

        #expect(first == ["messages:y", "messages:x"])
        #expect(first == second)
    }

    @Test("orphan semantic ids are dropped while ranking continues to the limit")
    internal func orphanSemanticIDsDropped() async throws {
        var items: [StowerTestItem] = []
        items.append(StowerTestItem(id: "a", text: "real alpha"))
        items.append(StowerTestItem(id: "b", text: "real beta"))
        var vectors: [String: [Float]] = [:]
        vectors["real alpha"] = [1, 0, 0, 0]
        vectors["real beta"] = [0, 1, 0, 0]
        vectors["zzz"] = [0, 0, 1, 0]
        let context = try await makeRetriever(items: items, vectorsByText: vectors)
        let orphan = StowerEmbeddingRecord(
            itemID: "messages:ghost",
            modelID: context.embedder.modelFingerprint,
            textHash: "h",
            vector: [0, 0, 1, 0]
        )
        try await context.store.upsert([orphan])

        let arms = try await context.retriever.evaluate("zzz", limit: 2)

        #expect(!arms.hybrid.contains { $0.item.id == "messages:ghost" })
        #expect(arms.hybrid.count == 2)
    }

    @Test("the query prefix is applied to queries only, never to stored texts")
    internal func queryPrefixOnQueriesOnly() async throws {
        var vectors: [String: [Float]] = [:]
        vectors["pizza tonight"] = [1, 0, 0, 0]
        vectors["pizza"] = [1, 0, 0, 0]
        let context = try await makeRetriever(
            items: [StowerTestItem(id: "a", text: "pizza tonight")],
            vectorsByText: vectors
        )

        _ = try await context.retriever.evaluate("pizza")

        #expect(await context.embedder.embeddedQueryForms == ["query: pizza"])
        #expect(await context.embedder.embeddedTexts.allSatisfy { !$0.hasPrefix("query: ") })
        #expect(await context.embedder.embeddedTexts.contains("pizza tonight"))
    }

    @Test("empty and whitespace queries return empty results without throwing")
    internal func emptyQueryShortCircuits() async throws {
        var vectors: [String: [Float]] = [:]
        vectors["pizza tonight"] = [1, 0, 0, 0]
        let context = try await makeRetriever(
            items: [StowerTestItem(id: "a", text: "pizza tonight")],
            vectorsByText: vectors
        )

        #expect(try await context.retriever.evaluate("").hybrid.isEmpty)
        #expect(try await context.retriever.evaluate("   ").hybrid.isEmpty)
        #expect(try await context.retriever.search("\"unterminated").isEmpty)
    }

    // MARK: - Fixtures

    private struct RetrieverContext {
        let retriever: StowerRetriever
        let embedder: StowerFakeEmbedder
        let store: StowerEmbeddingStore
        let index: StowerIndex
    }

    private func instant(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func makeRetriever(
        items: [StowerTestItem],
        vectorsByText: [String: [Float]]
    ) async throws -> RetrieverContext {
        let index = try StowerIndex.inMemory()
        try await index.replaceAll(with: items)
        let store = try StowerEmbeddingStore.inMemory()
        let embedder = StowerFakeEmbedder(dims: 4, vectorsByText: vectorsByText)
        let fingerprint = embedder.modelFingerprint
        let outcomes = try await embedder.embed(texts: items.map(\.text))
        let records = zip(items, outcomes).map { item, outcome -> StowerEmbeddingRecord in
            let vector: [Float]? = if case .vector(let value) = outcome { value } else { nil }
            return StowerEmbeddingRecord(
                itemID: item.namespacedID,
                modelID: fingerprint,
                textHash: "h",
                vector: vector
            )
        }
        try await store.upsert(records)
        let retriever = StowerRetriever(index: index, store: store, embedder: embedder)
        return RetrieverContext(
            retriever: retriever,
            embedder: embedder,
            store: store,
            index: index
        )
    }
}
