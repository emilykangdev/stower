import ArgumentParser
import Foundation
import StowerCore
import StowerMessages

/// `stower index` — snapshot, ingest, FTS-index, and delta-embed the window.
internal struct IndexCommand: AsyncParsableCommand {
    internal static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Index the recent Messages window and embed new messages."
    )

    @OptionGroup internal var shared: StowerSharedOptions

    @Option(name: .long, help: "Days of history to index.")
    internal var days: Int = 180

    internal func run() async throws {
        let locations = shared.locations()
        stowerWarnIfContactsDenied()
        let clock = ContinuousClock()

        // The index and embedding stores hold real message text. Refuse to write
        // them into a git repo unless they are gitignored, so private data can't
        // be committed by accident (same guard the eval query file gets).
        try stowerEnsureGitIgnored(locations.indexPath)
        try stowerEnsureGitIgnored(locations.storePath)

        // SQLite opens a file but never creates its parent dir; on a fresh
        // machine the default Index directory does not exist yet. Lock it to the
        // owner (0700): the index holds plaintext message text and, unlike
        // chat.db, is not TCC-protected, so other local users must not read it.
        try FileManager.default.createDirectory(
            at: locations.indexDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let items = try await ingest(locations: locations, clock: clock)
        let index = try StowerIndex(path: locations.indexPath)
        let ftsStart = clock.now
        try await index.replaceAll(with: items)
        print("fts: indexed \(items.count) items in \(elapsed(since: ftsStart, clock))")

        let store = try StowerEmbeddingStore(path: locations.storePath)
        let embedder = try stowerResolveEmbedder(modelPath: locations.modelPath, requireModel: true)
        let embedStart = clock.now
        let embedded = try await embed(items: items, store: store, embedder: embedder)
        let embedTime = elapsed(since: embedStart, clock)
        print("embed: \(embedded) new vectors in \(embedTime) (vs 101s baseline)")
        print("done: \(items.count) items, model \(embedder.modelFingerprint)")
    }

    private func ingest(
        locations: StowerLocations,
        clock: ContinuousClock
    ) async throws -> [StowerMessageItem] {
        do {
            let start = clock.now
            let reader = try StowerChatDatabaseReader()
            let items = try await reader.ingestWindow(days: days)
            print("ingest: \(items.count) messages in \(elapsed(since: start, clock))")
            return items
        } catch let error as StowerMessagesError {
            if case .fullDiskAccessMissing(let path) = error {
                stowerReportFullDiskAccess(path: path)
            } else {
                stowerStandardError(error.localizedDescription)
            }
            throw ExitCode.failure
        }
    }

    private func embed(
        items: [StowerMessageItem],
        store: StowerEmbeddingStore,
        embedder: StowerEmbedder
    ) async throws -> Int {
        let fingerprint = embedder.modelFingerprint
        let existing = try await store.existingHashes(fingerprint: fingerprint)
        let missing = items.filter { existing[namespacedID($0)] != stowerTextHash($0.text) }
        let batches = stride(from: 0, to: missing.count, by: 64).map { start in
            Array(missing[start..<min(start + 64, missing.count)])
        }
        for (offset, batch) in batches.enumerated() {
            let outcomes = try await embedder.embed(texts: batch.map(\.text))
            let records = zip(batch, outcomes).map { item, outcome in
                StowerEmbeddingRecord(
                    itemID: namespacedID(item),
                    modelID: fingerprint,
                    textHash: stowerTextHash(item.text),
                    vector: outcome.vectorValue
                )
            }
            try await store.upsert(records)
            print("  embed batch \(offset + 1)/\(batches.count) (\(records.count) items)")
        }
        try await store.prune(keepingItemIDs: Set(items.map(namespacedID)))
        return missing.count
    }

    private func namespacedID(_ item: StowerMessageItem) -> String {
        "\(item.source.rawValue):\(item.id)"
    }

    private func elapsed(since start: ContinuousClock.Instant, _ clock: ContinuousClock) -> String {
        let seconds = Double(start.duration(to: clock.now).components.seconds)
        let attoseconds = Double(start.duration(to: clock.now).components.attoseconds) / 1e18
        return String(format: "%.1fs", seconds + attoseconds)
    }
}

extension StowerEmbedOutcome {
    /// The vector for a successful outcome, or `nil` for a skipped one.
    internal var vectorValue: [Float]? {
        if case .vector(let value) = self { return value }
        return nil
    }
}
