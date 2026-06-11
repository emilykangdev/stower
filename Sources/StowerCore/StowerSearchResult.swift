/// A ranked match returned by the Stower index.
public struct StowerSearchResult: Sendable {
    /// The stored item that matched.
    public let item: StowerStoredItem

    /// An FTS5 excerpt with matching terms marked.
    public let snippet: String

    /// The raw FTS5 bm25 score.
    ///
    /// Lower values rank first.
    public let score: Double

    /// Groups ranked results by group identifier while preserving rank within each group.
    public static func groupedByGroupID(
        _ results: [StowerSearchResult]
    ) -> [String: [StowerSearchResult]] {
        Dictionary(grouping: results, by: \.item.groupID)
    }
}
