import StowerCore

/// A deterministic in-memory embedder for retriever tests.
///
/// Maps each known text to a fixed vector, records every text it embeds and
/// every query form it builds, and faithfully models the query-prefix asymmetry
/// so tests can assert the prefix is applied to queries only.
internal actor StowerFakeEmbedder: StowerEmbedder {
    internal let modelFingerprint: String
    private let queryPrefix: String
    private let vectorsByText: [String: [Float]]
    private let dims: Int
    internal private(set) var embeddedTexts: [String] = []
    internal private(set) var embeddedQueryForms: [String] = []

    internal init(
        fingerprint: String = "fake-model@v1",
        queryPrefix: String = "query: ",
        dims: Int,
        vectorsByText: [String: [Float]]
    ) {
        modelFingerprint = fingerprint
        self.queryPrefix = queryPrefix
        self.dims = dims
        self.vectorsByText = vectorsByText
    }

    internal func embed(texts: [String]) async throws -> [StowerEmbedOutcome] {
        embeddedTexts.append(contentsOf: texts)
        return texts.map { text in
            vectorsByText[text].map(StowerEmbedOutcome.vector) ?? .skipped("no fixture vector")
        }
    }

    internal func embedQuery(_ text: String) async throws -> [Float] {
        embeddedQueryForms.append(queryPrefix + text)
        return vectorsByText[text] ?? [Float](repeating: 0, count: dims)
    }
}
