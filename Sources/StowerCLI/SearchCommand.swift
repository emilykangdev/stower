import ArgumentParser
import Foundation
import StowerCore

/// `stower search` — ranked results for one query, with per-arm provenance.
internal struct SearchCommand: AsyncParsableCommand {
    internal static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the index (hybrid by default) and print ranked results."
    )

    @OptionGroup internal var shared: StowerSharedOptions

    @Argument(help: "The natural-language query.")
    internal var query: String

    @Option(name: .long, help: "Which arm to use: hybrid, fts, or semantic.")
    internal var arm: StowerSearchArm = .hybrid

    @Option(name: .long, help: "Maximum results to return.")
    internal var limit: Int = 10

    @Option(name: .customLong("rrf-k"), help: ArgumentHelp(visibility: .private))
    internal var fusionK: Int?

    @Option(name: .customLong("arm-depth"), help: ArgumentHelp(visibility: .private))
    internal var armDepth: Int?

    internal func run() async throws {
        let locations = shared.locations()
        let index = try await openNonEmptyIndex(at: locations.indexPath)
        let store = try StowerEmbeddingStore(path: locations.storePath)
        let embedder = try stowerResolveEmbedder(
            modelPath: locations.modelPath,
            requireModel: arm != .fts
        )
        let retriever = StowerRetriever(
            index: index,
            store: store,
            embedder: embedder,
            rrfDampening: fusionK ?? StowerRetriever.defaultRRFK,
            armDepth: armDepth ?? StowerRetriever.defaultArmDepth
        )

        // Hybrid/semantic silently fall back to FTS-only when the current model
        // has no vectors; say so loudly instead of pretending the semantic arm ran.
        if arm != .fts, try await store.count(fingerprint: embedder.modelFingerprint) == 0 {
            stowerStandardError(
                "warning: no embeddings for model \(embedder.modelFingerprint) — "
                    + "results are FTS-only. Run `stower index`."
            )
        }

        let results = try await retriever.search(query, arm: arm, limit: limit)
        guard !results.isEmpty else {
            print("no results for \"\(query)\" (\(arm.rawValue))")
            return
        }
        print("\(results.count) results for \"\(query)\" (\(arm.rawValue)):")
        for (rank, item) in results.enumerated() {
            print(stowerFormatResult(rank + 1, item))
        }
    }

    private func openNonEmptyIndex(at path: String) async throws -> StowerIndex {
        guard FileManager.default.fileExists(atPath: path) else {
            throw StowerCLIError.emptyIndex(path: path)
        }
        let index = try StowerIndex(path: path)
        guard try await index.count() > 0 else {
            throw StowerCLIError.emptyIndex(path: path)
        }
        return index
    }
}

extension StowerSearchArm: ExpressibleByArgument {}
