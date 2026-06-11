import GRDB

/// A source-agnostic, actor-isolated FTS5 search index.
public actor StowerIndex {
    private let databaseQueue: DatabaseQueue

    /// Opens or creates a file-backed Index DB.
    public init(path: String) throws {
        try self.init(databaseQueue: DatabaseQueue(path: path))
    }

    /// Creates an ephemeral in-memory Index DB for tests and previews.
    public static func inMemory() throws -> StowerIndex {
        try StowerIndex(databaseQueue: DatabaseQueue())
    }

    private init(databaseQueue: DatabaseQueue) throws {
        try StowerIndexSchema.prepare(databaseQueue)
        self.databaseQueue = databaseQueue
    }

    /// Destructively replaces all indexed content with the supplied adapter items.
    public func replaceAll<Item: StowerIndexedItem>(with items: [Item]) throws {
        let encoder = StowerStoredItem.makeMetadataEncoder()
        let storedItems = try items.map { try StowerStoredItem(from: $0, encoder: encoder) }
        try rebuild(with: storedItems)
    }

    /// Removes all indexed content.
    public func removeAll() throws {
        try rebuild(with: [])
    }

    /// Searches body and group-title text using safe tokenized FTS5 matching.
    ///
    /// Returns an empty array when `limit` is not positive or the query
    /// contains no searchable tokens.
    public func search(_ query: String, limit: Int = 50) throws -> [StowerSearchResult] {
        guard limit > 0, let pattern = FTS5Pattern(matchingAllTokensIn: query) else {
            return []
        }
        return try databaseQueue.read { database in
            try StowerSearchRow.fetchAll(
                database,
                sql: Self.searchSQL,
                arguments: [pattern, limit]
            ).map(\.result)
        }
    }

    private func rebuild(with items: [StowerStoredItem]) throws {
        try databaseQueue.write { database in
            try database.execute(sql: "DELETE FROM item")
            for item in items {
                try item.insert(database)
            }
            try database.execute(
                sql: "INSERT INTO item_fts(item_fts) VALUES ('rebuild')"
            )
        }
    }

    private static let searchSQL = """
        SELECT item.*,
               snippet(item_fts, 0, '<mark>', '</mark>', '…', 24) AS snippet,
               bm25(item_fts, 1.0, 0.25) AS score
        FROM item_fts
        JOIN item ON item.rowid = item_fts.rowid
        WHERE item_fts MATCH ?
        ORDER BY score ASC, item.timestamp DESC
        LIMIT ?
        """
}

private struct StowerSearchRow: FetchableRecord {
    fileprivate let item: StowerStoredItem
    fileprivate let snippet: String
    fileprivate let score: Double

    fileprivate init(row: Row) throws {
        item = try StowerStoredItem(row: row)
        snippet = row["snippet"]
        score = row["score"]
    }

    fileprivate var result: StowerSearchResult {
        StowerSearchResult(item: item, snippet: snippet, score: score)
    }
}
