import Foundation

/// Errors raised while loading or running a Core ML embedding model.
///
/// Every case is named with batch or path context and carries the exact remedy;
/// there is no catch-all, so a gate-night failure points straight at its fix.
public enum StowerEmbedderError: Error, LocalizedError, Sendable, Equatable {
    /// No `manifest.json` was found at the model directory.
    case modelNotFound(path: String)

    /// The manifest exists but could not be decoded.
    case manifestUnreadable(path: String, detail: String)

    /// The `.mlpackage` on disk no longer matches the manifest hash.
    case packageHashMismatch(expected: String, actual: String)

    /// The vendored tokenizer directory could not be loaded.
    case tokenizerLoadFailed(detail: String)

    /// A Core ML prediction failed for a specific batch.
    case predictionFailed(detail: String, batch: String)

    /// The embedder was asked to embed but no model is configured.
    case modelUnavailable

    /// A user-facing description with the runnable remedy where one exists.
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return """
                Embedding model not found at \(path) — run: \
                uv run Scripts/convert-embedding-model.py --model BAAI/bge-small-en-v1.5
                """
        case .manifestUnreadable(let path, let detail):
            return "Model manifest at \(path) is unreadable: \(detail)"
        case .packageHashMismatch(let expected, let actual):
            return
                "Model package hash mismatch (manifest \(expected), found \(actual)) — "
                + "re-run the convert script"
        case .tokenizerLoadFailed(let detail):
            return "Tokenizer failed to load from the model directory: \(detail)"
        case .predictionFailed(let detail, let batch):
            return "Core ML prediction failed (\(batch)): \(detail)"
        case .modelUnavailable:
            return "No embedding model is configured for this run."
        }
    }
}
