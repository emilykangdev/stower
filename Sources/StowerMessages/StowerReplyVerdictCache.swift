import Foundation
import GRDB

/// A rejected verdict-cache write.
internal enum StowerReplyVerdictCacheError: Error, Equatable {
    /// The verdict's confidence was non-finite or outside `0...1`.
    case invalidConfidence
}

/// Persistent, judge-keyed cache of reply-expectation verdicts.
///
/// Mirrors `StowerEmbeddingStore`: its own `reply-verdicts.sqlite`, keyed by
/// `(judge_version, message_guid)` with an `input_hash` so an edited message or
/// a changed judge re-judges instead of serving a stale verdict. It lets
/// `loadDebtBoard` read a trusted language-model verdict without ever blocking on
/// inference — `refreshJudgments` fills it in the background.
///
/// The trust boundary: writes reject a malformed payload, and reads resolve an
/// unknown/garbled source token to a miss, so the cache itself — not just a
/// provider check — enforces what may reach the board. Stores no plaintext and no
/// long-form content (M10): only hashes, the boolean, the confidence, and the
/// source token. Disposable (M9): a corruption, lock, or migration fault is a
/// miss, re-judged later, never a block — so every call site wraps cache access
/// in `try?`. Internal: it is an implementation detail of
/// `StowerDebtBoardProvider`, not a public seam.
internal actor StowerReplyVerdictCache {
    /// The cache schema version; a mismatch drops the cache, nothing else.
    internal static let currentVersion = 1

    /// The file name the cache owns beside `embeddings.sqlite`.
    internal static let fileName = "reply-verdicts.sqlite"

    private let databaseQueue: DatabaseQueue

    /// Opens or creates a file-backed verdict cache at `path`.
    internal init(path: String) throws {
        try self.init(path: path, schemaVersion: Self.currentVersion)
    }

    /// Creates an ephemeral in-memory cache for tests and previews.
    internal static func inMemory() throws -> StowerReplyVerdictCache {
        try StowerReplyVerdictCache(databaseQueue: DatabaseQueue(), schemaVersion: currentVersion)
    }

    /// Opens a file-backed cache, declaring the schema version to honor.
    ///
    /// Tests pass a bumped version to exercise the cache-drop path.
    internal init(path: String, schemaVersion: Int) throws {
        var configuration = Configuration()
        // The board must feel instant (M8: load p50 < 300ms) and never block on
        // the disposable cache (M9). A long busy wait would let a locked store
        // stall first paint, so cap it well under the budget: on contention a read
        // fails fast → heuristic for that row, and a write retries next refresh.
        configuration.busyMode = .timeout(0.1)
        try self.init(
            databaseQueue: DatabaseQueue(path: path, configuration: configuration),
            schemaVersion: schemaVersion
        )
    }

    private init(databaseQueue: DatabaseQueue, schemaVersion: Int) throws {
        try Self.prepare(databaseQueue, schemaVersion: schemaVersion)
        self.databaseQueue = databaseQueue
    }

    /// Returns the cached verdict only when version, guid, AND input hash match.
    ///
    /// A stale `input_hash` (the message text or kind changed) is a miss, so the
    /// caller re-judges rather than serving the old verdict.
    internal func existing(
        judgeVersion: String,
        guid: String,
        inputHash: String
    ) throws -> StowerReplyExpectation? {
        try databaseQueue.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT expects_reply, confidence, verdict_source FROM verdict
                        WHERE judge_version = ? AND message_guid = ? AND input_hash = ?
                        """,
                    arguments: [judgeVersion, guid, inputHash]
                )
            else {
                return nil
            }
            // An unrecognized source token means a corrupt row; treat it as a
            // miss (re-judge) rather than defaulting to the trusted source.
            let sourceToken: String = row["verdict_source"]
            guard let source = StowerReplyJudgeSource(rawValue: sourceToken) else {
                return nil
            }
            return StowerReplyExpectation(
                expectsReply: row["expects_reply"],
                replyExpectationConfidence: row["confidence"],
                verdictSource: source,
                reason: nil
            )
        }
    }

    /// Inserts or replaces the verdict for `(judgeVersion, guid)`.
    ///
    /// The cache is the trust boundary: it rejects a malformed payload (a
    /// non-finite or out-of-`0...1` confidence) so a future caller can't poison
    /// the cache by bypassing a provider check. Idempotent (M16): a second upsert
    /// of the same key updates the one row in place rather than duplicating it, so
    /// an overlapping refresh wastes no storage and never double-counts.
    internal func upsert(
        judgeVersion: String,
        guid: String,
        inputHash: String,
        verdict: StowerReplyExpectation
    ) throws {
        guard verdict.replyExpectationConfidence.isFinite,
            (0...1).contains(verdict.replyExpectationConfidence)
        else {
            throw StowerReplyVerdictCacheError.invalidConfidence
        }
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO verdict (
                      judge_version, message_guid, input_hash,
                      expects_reply, confidence, verdict_source
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(judge_version, message_guid) DO UPDATE SET
                      input_hash = excluded.input_hash,
                      expects_reply = excluded.expects_reply,
                      confidence = excluded.confidence,
                      verdict_source = excluded.verdict_source
                    """,
                arguments: [
                    judgeVersion, guid, inputHash,
                    verdict.expectsReply, verdict.replyExpectationConfidence,
                    verdict.verdictSource.rawValue
                ]
            )
        }
    }

    /// Deletes rows whose guid is gone OR whose judge version is retired (M15).
    ///
    /// Bounds cache growth after a shrinking window or a judge-version bump
    /// without touching rows still keyed by a live guid and version.
    internal func prune(keepingGUIDs: Set<String>, keepingVersions: Set<String>) throws {
        try databaseQueue.write { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT rowid, message_guid, judge_version FROM verdict"
            )
            let orphans = rows.compactMap { row -> Int64? in
                let guid: String = row["message_guid"]
                let version: String = row["judge_version"]
                let kept = keepingGUIDs.contains(guid) && keepingVersions.contains(version)
                return kept ? nil : row["rowid"]
            }
            for start in stride(from: 0, to: orphans.count, by: 500) {
                let chunk = Array(orphans[start..<min(start + 500, orphans.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try database.execute(
                    sql: "DELETE FROM verdict WHERE rowid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }
}
