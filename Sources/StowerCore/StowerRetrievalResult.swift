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

/// A conversation-level result: the best-ranked item in a group, plus how many
/// of the group's items surfaced in the ranking.
///
/// Aggregate recall ("did I text anyone about the discussion meeting?") wants
/// answers shaped as conversations, not individual messages; this collapses a
/// ranked item list to one entry per conversation.
public struct StowerGroupedResult: Sendable {
    /// The conversation identifier the group collapsed on.
    public let groupID: String

    /// The conversation display title.
    public let groupTitle: String

    /// The highest-ranked item in this conversation.
    public let best: StowerRetrievedItem

    /// How many of the conversation's items appeared in the source ranking.
    public let matchCount: Int
}

extension Array where Element == StowerRetrievedItem {
    /// Collapses ranked items to conversations, best group first.
    ///
    /// The retriever returns items in a deterministic fused-rank order, so a
    /// group taking the slot of its first-seen (highest-ranked) item preserves
    /// that ranking across conversations.
    public func stowerGroupedByConversation() -> [StowerGroupedResult] {
        var order: [String] = []
        var byGroup: [String: [StowerRetrievedItem]] = [:]
        for hit in self {
            let groupID = hit.item.groupID
            if byGroup[groupID] == nil { order.append(groupID) }
            byGroup[groupID, default: []].append(hit)
        }
        return order.compactMap { groupID in
            guard let hits = byGroup[groupID], let best = hits.first else { return nil }
            return StowerGroupedResult(
                groupID: groupID,
                groupTitle: best.item.groupTitle,
                best: best,
                matchCount: hits.count
            )
        }
    }
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
