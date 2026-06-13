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

    /// The pre-registered suite size; the "≥7/10" verdict requires the full set.
    internal static let minimumSuiteSize = 10

    /// Items pulled per arm before conversation grouping; deep enough that a few
    /// chatty conversations can't crowd out other top-N conversations.
    private static let itemCandidateBudget = 100

    @OptionGroup internal var shared: StowerSharedOptions

    @Argument(help: "TSV: query <TAB> expected-target-substring <TAB> in-window|out-of-window.")
    internal var queriesFile: String

    @Option(name: .long, help: "Top-N conversations per arm to score against.")
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
        // The "≥7/10" criterion is only meaningful against the full pre-registered
        // suite; a truncated file (e.g. 7 in-window queries) must not pass as 7/10.
        guard queries.count >= Self.minimumSuiteSize else {
            throw StowerCLIError.incompleteGateSuite(
                found: queries.count,
                required: Self.minimumSuiteSize
            )
        }

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
            // Retrieve a deep item set, then score against the top-N conversations.
            let arms = try await retriever.evaluate(entry.query, limit: Self.itemCandidateBudget)
            let hybridHit = armHit(arms.hybrid, expected: entry.expected)
            report(entry: entry, arms: arms, hybridHit: hybridHit, into: &transcript)
            if entry.inWindow {
                inWindowTotal += 1
                inWindowHits += hybridHit ? 1 : 0
            }
        }
        let passed = inWindowHits >= Self.inWindowHitCriterion
        transcript.line(
            "GATE: \(inWindowHits)/\(inWindowTotal) in-window hybrid hits "
                + "(criterion ≥ \(Self.inWindowHitCriterion)) — \(passed ? "PASS" : "FAIL")"
        )
        try transcript.flush()
        // Exit non-zero on FAIL so CI and scripts don't read a failed gate as success.
        if !passed { throw ExitCode.failure }
    }

    private func preflight(
        index: StowerIndex,
        store: StowerEmbeddingStore,
        embedder: StowerEmbedder,
        into transcript: inout StowerTranscript
    ) async throws {
        let itemCount = try await index.count()
        let embeddingCount = try await store.count(fingerprint: embedder.modelFingerprint)
        // Processed = items with a cache row (embedded OR explicitly skipped) for
        // the current model. After a complete index this equals itemCount; a
        // shortfall means an interrupted index or a model change, where "hybrid"
        // would silently be mostly FTS.
        let processed = try await store.existingHashes(fingerprint: embedder.modelFingerprint).count
        let coverage = itemCount > 0 ? Double(processed) / Double(itemCount) * 100 : 0
        let percent = String(format: "%.1f", coverage)
        let fingerprint = embedder.modelFingerprint
        transcript.line(
            "preflight: \(itemCount) items, \(embeddingCount) embeddings, "
                + "\(processed) processed (\(percent)% coverage), model \(fingerprint)"
        )
        guard allowFTSOnly else {
            guard embeddingCount > 0 else { throw StowerCLIError.noEmbeddingsForGate }
            guard processed >= itemCount else {
                throw StowerCLIError.incompleteCoverage(items: itemCount, processed: processed)
            }
            return
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
        // Aggregate recall: a hit is the expected *conversation* surfacing in the
        // top-N conversations (expected = a conversation/person name), with a
        // message-text fallback for point-recall queries — bounded to those same
        // top-N conversations so a deep, off-topic item can't manufacture a hit.
        let topGroupIDs = Set(
            results.stowerGroupedByConversation().prefix(limit).map(\.groupID)
        )
        return results.contains { item in
            guard topGroupIDs.contains(item.item.groupID) else { return false }
            return item.item.groupTitle.localizedCaseInsensitiveContains(expected)
                || item.item.text.localizedCaseInsensitiveContains(expected)
        }
    }

    private func topSnippet(_ results: [StowerRetrievedItem]) -> String {
        let groups = results.stowerGroupedByConversation()
        guard let top = groups.first else { return "(none)" }
        let rawBody = top.best.snippet ?? String(top.best.item.text.prefix(60))
        let body = stowerSanitizedForTerminal(rawBody)
        let title = stowerSanitizedForTerminal(top.groupTitle)
        return "[\(groups.count) convo(s)] \(title): \(body)"
    }

    private func loadQueries() throws -> [EvalQuery] {
        let contents: String
        do {
            contents = try String(contentsOfFile: queriesFile, encoding: .utf8)
        } catch {
            throw StowerCLIError.queryFileUnreadable(
                path: queriesFile,
                reason: (error as NSError).localizedDescription
            )
        }
        // Parse strictly: blank/comment lines are skipped, but a malformed row
        // throws with its line number rather than being silently dropped — a
        // dropped row would shrink the gate set and could spuriously PASS.
        var queries: [EvalQuery] = []
        var seen: Set<String> = []
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let query = try parseQueryLine(trimmed, number: index + 1)
            // Reject duplicates so a suite padded with repeats can't meet the size
            // requirement and inflate the verdict.
            guard seen.insert(query.query.lowercased()).inserted else {
                throw StowerCLIError.malformedQueryLine(
                    path: queriesFile,
                    number: index + 1,
                    reason: "duplicate query — each pre-registered query must be distinct"
                )
            }
            queries.append(query)
        }
        guard !queries.isEmpty else { throw StowerCLIError.emptyQueryFile(path: queriesFile) }
        return queries
    }

    private func parseQueryLine(_ line: String, number: Int) throws -> EvalQuery {
        let fields = line.components(separatedBy: "\t")
        guard fields.count == 3 else {
            throw StowerCLIError.malformedQueryLine(
                path: queriesFile,
                number: number,
                reason: "expected 3 tab-separated fields, found \(fields.count)"
            )
        }
        let query = fields[0].trimmingCharacters(in: .whitespaces)
        let expected = fields[1].trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !expected.isEmpty else {
            throw StowerCLIError.malformedQueryLine(
                path: queriesFile,
                number: number,
                reason: "query and expected-target fields must be non-empty"
            )
        }
        let inWindow: Bool
        switch fields[2] {
        case "in-window": inWindow = true
        case "out-of-window": inWindow = false
        default:
            throw StowerCLIError.malformedQueryLine(
                path: queriesFile,
                number: number,
                reason: "third field must be in-window or out-of-window, found '\(fields[2])'"
            )
        }
        return EvalQuery(query: query, expected: expected, inWindow: inWindow)
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
