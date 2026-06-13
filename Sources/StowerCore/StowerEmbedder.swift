/// The outcome of embedding one input text.
///
/// Positionally aligned with the input array: a skipped input keeps its slot
/// rather than being dropped, so a later vector is never shifted onto the wrong
/// message — a gate-corrupting bug class.
public enum StowerEmbedOutcome: Sendable, Equatable {
    /// A computed embedding vector.
    case vector([Float])

    /// The text was deliberately not embedded, with a human-readable reason.
    case skipped(String)
}

/// A model-agnostic seam for turning text into vectors.
///
/// Conformers carry their own model identity in `modelFingerprint`, so swapping
/// the embedding model is a re-embed against a new cache key, not a code change.
/// The protocol is `async` because a real conformer loads and runs Core ML.
public protocol StowerEmbedder: Sendable {
    /// Embeds stored texts without any query prefix.
    ///
    /// The returned array is positionally aligned with `texts` and has the same
    /// count: index `i` is the outcome for `texts[i]`.
    func embed(texts: [String]) async throws -> [StowerEmbedOutcome]

    /// Embeds a search query, applying the model's query prefix when it has one.
    func embedQuery(_ text: String) async throws -> [Float]

    /// The model identity used as the cache key (`model_id@revision`).
    var modelFingerprint: String { get }
}
