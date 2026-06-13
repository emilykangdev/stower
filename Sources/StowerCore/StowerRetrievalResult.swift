/// Which retrieval arm(s) a search should use.
public enum StowerSearchArm: String, Sendable, CaseIterable {
    /// Reciprocal-rank fusion of the FTS and semantic arms.
    case hybrid
    /// Keyword FTS5 only.
    case fts
    /// Embedding cosine only.
    case semantic
}

/// One ranked result with its per-arm provenance.
///
/// `ftsRank` / `semanticRank` are the zero-based positions the item held in each
/// arm (`nil` when that arm did not surface it); `fusedScore` is its RRF score.
public struct StowerRetrievedItem: Sendable {
    /// The resolved stored item.
    public let item: StowerStoredItem

    /// The FTS excerpt, when the item came through the keyword arm.
    public let snippet: String?

    /// The item's zero-based rank in the FTS arm, if present.
    public let ftsRank: Int?

    /// The item's zero-based rank in the semantic arm, if present.
    public let semanticRank: Int?

    /// The reciprocal-rank-fusion score used for the final ordering.
    public let fusedScore: Double
}

/// The result of one retrieval pass, exposing every arm.
///
/// A single `evaluate` pass fills all three arms from one query embedding, so
/// the eval harness can print FTS, semantic, and hybrid side by side.
public struct StowerArmResults: Sendable {
    /// Keyword-arm results, best first.
    public let fts: [StowerRetrievedItem]

    /// Semantic-arm results, best first.
    public let semantic: [StowerRetrievedItem]

    /// Fused results, best first.
    public let hybrid: [StowerRetrievedItem]

    /// An empty result for short-circuited queries.
    public static let empty = StowerArmResults(fts: [], semantic: [], hybrid: [])
}
