import ArgumentParser
import Foundation
import StowerCore

/// `stower eval` — score the pre-registered query set, three arms side by side.
internal struct EvalCommand: AsyncParsableCommand {
    internal static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Run the pre-registered recall queries and score the gate."
    )

    internal static let inWindowHitCriterion = 7

    @OptionGroup internal var shared: StowerSharedOptions

    @Argument(help: "TSV: query <TAB> expected-target-substring <TAB> in-window|out-of-window.")
    internal var queriesFile: String

    @Option(name: .long, help: "Results per arm.")
    internal var limit: Int = 10

    @Flag(
        name: .customLong("allow-fts-only"),
        help: "Permit a run with zero embeddings (FTS-only)."
    )
    internal var allowFTSOnly = false

    @Option(name: .long, help: "Write the transcript to this (gitignored) path.")
    internal var out: String?

    internal func run() async throws {
        try stowerEnsureGitIgnored(queriesFile)
        if let out { try stowerEnsureGitIgnored(out) }
        let queries = try loadQueries()

        let locations = shared.locations()
        let index = try await openNonEmptyIndex(at: locations.indexPath)
        let store = try StowerEmbeddingStore(path: locations.storePath)
        let embedder = try stowerResolveEmbedder(
            modelPath: locations.modelPath,
            requireModel: !allowFTSOnly
        )
        var transcript = StowerTranscript(out: out)
        try await preflight(index: index, store: store, embedder: embedder, into: &transcript)

        let retriever = StowerRetriever(index: index, store: store, embedder: embedder)
        var inWindowHits = 0
        var inWindowTotal = 0
        for entry in queries {
            let arms = try await retriever.evaluate(entry.query, limit: limit)
            let hybridHit = armHit(arms.hybrid, expected: entry.expected)
            report(entry: entry, arms: arms, hybridHit: hybridHit, into: &transcript)
            if entry.inWindow {
                inWindowTotal += 1
                inWindowHits += hybridHit ? 1 : 0
            }
        }
        let verdict = inWindowHits >= Self.inWindowHitCriterion ? "PASS" : "FAIL"
        transcript.line(
            "GATE: \(inWindowHits)/\(inWindowTotal) in-window hybrid hits "
                + "(criterion ≥ \(Self.inWindowHitCriterion)) — \(verdict)"
        )
        try transcript.flush()
    }

    private func preflight(
        index: StowerIndex,
        store: StowerEmbeddingStore,
        embedder: StowerEmbedder,
        into transcript: inout StowerTranscript
    ) async throws {
        let itemCount = try await index.count()
        let embeddingCount = try await store.vectors(fingerprint: embedder.modelFingerprint).count
        let coverage = itemCount > 0 ? Double(embeddingCount) / Double(itemCount) * 100 : 0
        let percent = String(format: "%.1f", coverage)
        transcript.line(
            "preflight: \(itemCount) items, \(embeddingCount) embeddings "
                + "(\(percent)% coverage), model \(embedder.modelFingerprint)"
        )
        if embeddingCount == 0 && !allowFTSOnly {
            throw StowerCLIError.noEmbeddingsForGate
        }
    }

    private func report(
        entry: EvalQuery,
        arms: StowerArmResults,
        hybridHit: Bool,
        into transcript: inout StowerTranscript
    ) {
        transcript.line("")
        transcript.line("Q: \(entry.query)  [\(entry.inWindow ? "in-window" : "out-of-window")]")
        transcript.line("  expected: \(entry.expected)")
        transcript.line(
            "  fts      \(armHit(arms.fts, expected: entry.expected) ? "HIT " : "MISS")"
                + "  \(topSnippet(arms.fts))"
        )
        transcript.line(
            "  semantic \(armHit(arms.semantic, expected: entry.expected) ? "HIT " : "MISS")"
                + "  \(topSnippet(arms.semantic))"
        )
        transcript.line("  hybrid   \(hybridHit ? "HIT " : "MISS")  \(topSnippet(arms.hybrid))")
    }

    private func armHit(_ results: [StowerRetrievedItem], expected: String) -> Bool {
        results.contains { $0.item.text.localizedCaseInsensitiveContains(expected) }
    }

    private func topSnippet(_ results: [StowerRetrievedItem]) -> String {
        guard let first = results.first else { return "(none)" }
        let body = first.snippet ?? String(first.item.text.prefix(60))
        return body.replacingOccurrences(of: "\n", with: " ")
    }

    private func loadQueries() throws -> [EvalQuery] {
        guard let contents = try? String(contentsOfFile: queriesFile, encoding: .utf8) else {
            throw StowerCLIError.queryFileUnreadable(path: queriesFile)
        }
        let queries = contents.split(separator: "\n").compactMap { EvalQuery(line: String($0)) }
        guard !queries.isEmpty else { throw StowerCLIError.queryFileUnreadable(path: queriesFile) }
        return queries
    }

    private func openNonEmptyIndex(at path: String) async throws -> StowerIndex {
        guard FileManager.default.fileExists(atPath: path) else {
            throw StowerCLIError.emptyIndex(path: path)
        }
        let index = try StowerIndex(path: path)
        guard try await index.count() > 0 else { throw StowerCLIError.emptyIndex(path: path) }
        return index
    }
}

/// One parsed line of the pre-registered eval set.
internal struct EvalQuery {
    internal let query: String
    internal let expected: String
    internal let inWindow: Bool

    internal init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let fields = trimmed.components(separatedBy: "\t")
        guard fields.count == 3 else { return nil }
        query = fields[0]
        expected = fields[1]
        inWindow = fields[2] == "in-window"
    }
}

/// Buffers eval output, printing live and optionally writing to a guarded file.
internal struct StowerTranscript {
    private let out: String?
    private var lines: [String] = []

    internal init(out: String?) { self.out = out }

    internal mutating func line(_ text: String) {
        print(text)
        lines.append(text)
    }

    internal func flush() throws {
        guard let out else { return }
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
