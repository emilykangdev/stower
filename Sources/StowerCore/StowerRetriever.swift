import Foundation

/// Hybrid retrieval over an FTS index and an embedding cache, fused with RRF.
///
/// Composes a `StowerIndex` (keyword arm), a `StowerEmbeddingStore` (semantic
/// arm), and a `StowerEmbedder` (query vectors). Reciprocal-rank fusion and its
/// constants live here and nowhere else in the codebase.
public actor StowerRetriever {
    /// The default RRF dampening constant (the `k` in `1 / (k + rank)`).
    public static let defaultRRFK = 60

    /// The default number of candidates pulled from each arm before fusion.
    public static let defaultArmDepth = 100

    private let index: StowerIndex
    private let store: StowerEmbeddingStore
    private let embedder: StowerEmbedder
    private let rrfK: Int
    private let armDepth: Int
    private var cachedVectors: StowerVectorCache?

    /// Composes the retriever.
    ///
    /// `rrfDampening` and `armDepth` exist so the CLI can tune fusion at runtime
    /// without a rebuild; both default to the single-sourced constants above.
    public init(
        index: StowerIndex,
        store: StowerEmbeddingStore,
        embedder: StowerEmbedder,
        rrfDampening rrfK: Int = StowerRetriever.defaultRRFK,
        armDepth: Int = StowerRetriever.defaultArmDepth
    ) {
        self.index = index
        self.store = store
        self.embedder = embedder
        self.rrfK = rrfK
        self.armDepth = armDepth
    }

    /// Searches a single arm (or the fused hybrid) and returns ranked items.
    public func search(
        _ query: String,
        arm: StowerSearchArm = .hybrid,
        limit: Int = 10
    ) async throws -> [StowerRetrievedItem] {
        // Pure keyword path: never load the vector cache or touch the embedder, so
        // FTS search keeps working with no model, a corrupt model, or stale vectors.
        if arm == .fts {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else {
                return []
            }
            return ftsArm(try await index.search(query, limit: armDepth), limit: limit)
        }
        let arms = try await evaluate(query, limit: limit)
        return arm == .semantic ? arms.semantic : arms.hybrid
    }

    /// Runs every arm from one query embedding and returns all three rankings.
    public func evaluate(_ query: String, limit: Int = 10) async throws -> StowerArmResults {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else {
            return .empty
        }
        let ftsHits = try await index.search(query, limit: armDepth)
        let cache = try await vectorCache()
        guard !cache.isEmpty else {
            // First run / FTS-only: short-circuit before any embed call.
            let fts = ftsArm(ftsHits, limit: limit)
            return StowerArmResults(fts: fts, semantic: [], hybrid: fts)
        }
        let queryVector = try await embedder.embedQuery(query)
        let semHits = cache.topK(query: queryVector, count: armDepth)
        let semItems = try await resolve(semHits)
        return StowerArmResults(
            fts: ftsArm(ftsHits, limit: limit),
            semantic: semanticArm(semHits, items: semItems, limit: limit),
            hybrid: fuse(ftsHits: ftsHits, semHits: semHits, semItems: semItems, limit: limit)
        )
    }

    private func vectorCache() async throws -> StowerVectorCache {
        if let cachedVectors { return cachedVectors }
        let built = StowerVectorCache(
            try await store.loadFlatVectors(fingerprint: embedder.modelFingerprint)
        )
        cachedVectors = built
        return built
    }

    // MARK: - Arms and fusion

    private func rrfTerm(_ rank: Int) -> Double { 1.0 / Double(rrfK + rank + 1) }

    private func ftsArm(_ hits: [StowerSearchResult], limit: Int) -> [StowerRetrievedItem] {
        hits.prefix(limit).enumerated().map { rank, hit in
            StowerRetrievedItem(
                item: hit.item,
                snippet: hit.snippet,
                ftsRank: rank,
                semanticRank: nil,
                fusedScore: rrfTerm(rank)
            )
        }
    }

    private func semanticArm(
        _ semHits: [(itemID: String, rank: Int)],
        items: [String: StowerStoredItem],
        limit: Int
    ) -> [StowerRetrievedItem] {
        // Orphan ids (a cache entry that outlived its item) are dropped, and
        // ranking continues down the list until `limit` real items are found.
        semHits
            .compactMap { hit -> StowerRetrievedItem? in
                guard let item = items[hit.itemID] else { return nil }
                return StowerRetrievedItem(
                    item: item,
                    snippet: nil,
                    ftsRank: nil,
                    semanticRank: hit.rank,
                    fusedScore: rrfTerm(hit.rank)
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Resolves semantic-only ids to items via the index; orphans are absent.
    private func resolve(
        _ semHits: [(itemID: String, rank: Int)]
    ) async throws -> [String: StowerStoredItem] {
        let resolved = try await index.items(ids: semHits.map(\.itemID))
        return Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func fuse(
        ftsHits: [StowerSearchResult],
        semHits: [(itemID: String, rank: Int)],
        semItems: [String: StowerStoredItem],
        limit: Int
    ) -> [StowerRetrievedItem] {
        var candidates: [String: FusionCandidate] = [:]
        for (rank, hit) in ftsHits.enumerated() {
            candidates[hit.item.id] = FusionCandidate(
                item: hit.item,
                snippet: hit.snippet,
                ftsRank: rank,
                semanticRank: nil
            )
        }
        for hit in semHits {
            guard let item = candidates[hit.itemID]?.item ?? semItems[hit.itemID] else { continue }
            let existing = candidates[hit.itemID]
            candidates[hit.itemID] = FusionCandidate(
                item: item,
                snippet: existing?.snippet,
                ftsRank: existing?.ftsRank,
                semanticRank: hit.rank
            )
        }
        return rankCandidates(candidates.values, limit: limit)
    }

    private func rankCandidates<Candidates: Sequence>(
        _ candidates: Candidates,
        limit: Int
    ) -> [StowerRetrievedItem] where Candidates.Element == FusionCandidate {
        candidates
            .map { candidate in
                StowerRetrievedItem(
                    item: candidate.item,
                    snippet: candidate.snippet,
                    ftsRank: candidate.ftsRank,
                    semanticRank: candidate.semanticRank,
                    fusedScore: (candidate.ftsRank.map(rrfTerm) ?? 0)
                        + (candidate.semanticRank.map(rrfTerm) ?? 0)
                )
            }
            .sorted(by: Self.fusedOrder)
            .prefix(limit)
            .map { $0 }
    }

    /// Deterministic total order: fused score desc, timestamp desc, then id asc.
    ///
    /// RRF with `k = 60` produces frequent exact score ties; without a full total
    /// order, dictionary iteration order would make gate verdicts flaky.
    private static func fusedOrder(_ lhs: StowerRetrievedItem, _ rhs: StowerRetrievedItem) -> Bool {
        if lhs.fusedScore != rhs.fusedScore { return lhs.fusedScore > rhs.fusedScore }
        if lhs.item.timestamp != rhs.item.timestamp {
            return lhs.item.timestamp > rhs.item.timestamp
        }
        return lhs.item.id < rhs.item.id
    }
}

/// A fusion work item carrying both arms' ranks for one candidate id.
private struct FusionCandidate {
    let item: StowerStoredItem
    let snippet: String?
    let ftsRank: Int?
    let semanticRank: Int?
}
