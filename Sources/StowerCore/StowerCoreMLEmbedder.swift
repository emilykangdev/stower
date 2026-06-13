import CoreML
import Foundation
import Tokenizers

/// A `StowerEmbedder` backed by a converted Core ML model and a vendored tokenizer.
///
/// An actor: it owns non-`Sendable` `MLModel` and tokenizer state and isolates it.
/// The `.mlpackage` is compiled once to an `.mlmodelc` cached by fingerprint
/// (Core ML cannot load a raw `.mlpackage` at runtime); the heavy load is lazy,
/// so an FTS-only run never pays for a model it will not use. Pooling, prefix,
/// dims, and special-token ids all come from the manifest.
public actor StowerCoreMLEmbedder: StowerEmbedder {
    /// The model identity, available without loading the model.
    public nonisolated let modelFingerprint: String

    private static let maxBatch = 64
    private static let minimumMeaningfulTokens = 2

    private let modelDirectory: URL
    private let manifest: StowerModelManifest
    private var loaded: LoadedModel?

    /// Reads the manifest (cheap) without compiling or loading the model.
    public init(modelDirectory: URL) throws {
        let manifest = try StowerModelManifest.load(from: modelDirectory)
        self.modelDirectory = modelDirectory
        self.manifest = manifest
        modelFingerprint = manifest.fingerprint
    }

    /// Embeds stored texts, returning outcomes positionally aligned with input.
    public func embed(texts: [String]) async throws -> [StowerEmbedOutcome] {
        guard !texts.isEmpty else { return [] }
        let model = try await load()
        var outcomes = [StowerEmbedOutcome](repeating: .skipped("unprocessed"), count: texts.count)
        var positions: [Int] = []
        var sequences: [[Int]] = []
        for (offset, text) in texts.enumerated() {
            switch model.policy.plan(subwordIDs: subwordIDs(for: text, in: model)) {
            case .skipped(let reason): outcomes[offset] = .skipped(reason)
            case .encoded(let ids): positions.append(offset); sequences.append(ids)
            }
        }
        let vectors = try predictAll(sequences, in: model)
        for (index, position) in positions.enumerated() {
            outcomes[position] = .vector(vectors[index])
        }
        return outcomes
    }

    /// Embeds a query: the manifest prefix is applied, and it is never skipped.
    public func embedQuery(_ text: String) async throws -> [Float] {
        let model = try await load()
        let ids = subwordIDs(for: manifest.queryPrefix + text, in: model)
        let encoded = model.policy.encodeQuery(subwordIDs: ids)
        guard let vector = try predictAll([encoded], in: model).first else {
            throw StowerEmbedderError.predictionFailed(detail: "empty query result", batch: "query")
        }
        return vector
    }

    // MARK: - Loading

    private struct LoadedModel {
        let model: MLModel
        let tokenizer: Tokenizer
        let policy: StowerTokenizationPolicy
    }

    private func load() async throws -> LoadedModel {
        if let loaded { return loaded }
        try manifest.verifyPackageHash(in: modelDirectory)
        let compiled = try await compiledModelURL()
        let model = try MLModel(contentsOf: compiled, configuration: MLModelConfiguration())
        let tokenizer = try await loadTokenizer()
        let policy = StowerTokenizationPolicy(
            clsTokenID: manifest.clsTokenID,
            sepTokenID: manifest.sepTokenID,
            padTokenID: manifest.padTokenID,
            unknownTokenID: tokenizer.unknownTokenId,
            maxTokens: manifest.maxTokens,
            minimumMeaningfulTokens: Self.minimumMeaningfulTokens
        )
        let result = LoadedModel(model: model, tokenizer: tokenizer, policy: policy)
        loaded = result
        return result
    }

    private func loadTokenizer() async throws -> Tokenizer {
        let directory = modelDirectory.appendingPathComponent(manifest.tokenizerDir)
        do {
            return try await AutoTokenizer.from(modelFolder: directory)
        } catch {
            throw StowerEmbedderError.tokenizerLoadFailed(detail: "\(error)")
        }
    }

    /// Compiles the `.mlpackage` to a fingerprint-keyed `.mlmodelc`, once.
    ///
    /// Installs atomically via a staging copy so an interrupted compile cannot
    /// leave a corrupt cache that poisons every later run.
    private func compiledModelURL() async throws -> URL {
        let cacheDirectory = Self.compiledCacheDirectory(fingerprint: manifest.fingerprint)
        let finalURL = cacheDirectory.appendingPathComponent("model.mlmodelc")
        if FileManager.default.fileExists(atPath: finalURL.path) { return finalURL }
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let packageURL = modelDirectory.appendingPathComponent(manifest.mlpackage)
        let compiled = try await MLModel.compileModel(at: packageURL)
        let staging = cacheDirectory.appendingPathComponent("staging-\(UUID().uuidString).mlmodelc")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: compiled, to: staging)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: staging)
            return finalURL
        }
        try FileManager.default.moveItem(at: staging, to: finalURL)
        return finalURL
    }

    private static func compiledCacheDirectory(fingerprint: String) -> URL {
        let slug = fingerprint.replacingOccurrences(of: "/", with: "_")
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Stower/CompiledModels/\(slug)", isDirectory: true)
    }

    // MARK: - Tokenization and prediction

    private func subwordIDs(for text: String, in model: LoadedModel) -> [Int] {
        let fallback = model.tokenizer.unknownTokenId ?? 0
        return model.tokenizer.tokenize(text: text).map {
            model.tokenizer.convertTokenToId($0) ?? fallback
        }
    }

    private func predictAll(_ sequences: [[Int]], in model: LoadedModel) throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(sequences.count)
        for start in stride(from: 0, to: sequences.count, by: Self.maxBatch) {
            let chunk = Array(sequences[start..<min(start + Self.maxBatch, sequences.count)])
            let padded = model.policy.padded(chunk)
            vectors.append(
                contentsOf: try predict(ids: padded.ids, mask: padded.mask, model: model.model)
            )
        }
        return vectors
    }

    private func predict(ids: [[Int]], mask: [[Int]], model: MLModel) throws -> [[Float]] {
        guard let width = ids.first?.count else { return [] }
        let rows = ids.count
        let idValue = MLFeatureValue(multiArray: try Self.int32Array(ids, rows: rows, width: width))
        let maskValue = MLFeatureValue(
            multiArray: try Self.int32Array(mask, rows: rows, width: width)
        )
        var features: [String: MLFeatureValue] = [:]
        features[manifest.inputIDsName] = idValue
        features[manifest.attentionMaskName] = maskValue
        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let output = try model.prediction(from: provider)
        guard let embeddings = output.featureValue(for: manifest.outputName)?.multiArrayValue else {
            throw StowerEmbedderError.predictionFailed(
                detail: "missing output \(manifest.outputName)",
                batch: "rows=\(rows) width=\(width)"
            )
        }
        return (0..<rows).map { row in
            (0..<manifest.dims).map {
                embeddings[[NSNumber(value: row), NSNumber(value: $0)]].floatValue
            }
        }
    }

    private static func int32Array(
        _ values: [[Int]],
        rows: Int,
        width: Int
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [NSNumber(value: rows), NSNumber(value: width)],
            dataType: .int32
        )
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: rows * width)
        for row in 0..<rows {
            for column in 0..<width {
                pointer[row * width + column] = Int32(values[row][column])
            }
        }
        return array
    }
}
