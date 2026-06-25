import Foundation
import GRDB

/// A draft-store open failure with no more specific SQLite cause.
///
/// Thrown only when every bounded open attempt hit a transient lock — i.e. a real,
/// surfaced contention failure, not a healthy busy file the retry resolved.
internal enum StowerDraftStoreError: Error, Equatable {
    /// Every bounded open attempt failed on a lock; treated as a real error.
    case openFailed
}

/// Persistent, handle-keyed store of the user's private per-conversation drafts.
///
/// PRECIOUS, app-owned data — the opposite posture from the disposable
/// `StowerReplyVerdictCache`. A draft is "what I want to say to this person,"
/// composed over time and revisited across sessions, so it is NEVER erased to
/// recover: migrations are additive-only (no `eraseIfStale`), and an unopenable
/// file is quarantined aside (renamed `…corrupt-<ts>`, never deleted) so the bytes
/// survive for recovery.
///
/// Keyed by the conversation's normalized handle (`StowerDraftKey`) so a draft is
/// immune to chat-GUID churn, SMS<->iMessage flips, and Contacts edits. It runs on
/// a default rollback-journaled `DatabaseQueue` (NOT WAL — so there are no
/// `-wal`/`-shm` sidecars, only a transient `-journal` during a write) and pins
/// `synchronous = FULL` so every committed change is fsync-durable: the
/// never-lose-a-draft promise is a property, not a hope. A blank/whitespace body
/// deletes the row — an empty draft is no draft.
public actor StowerDraftStore {
    /// The file name the store owns under `Application Support/Stower`.
    public static let fileName = "drafts.sqlite"

    /// How long a write waits on a (single-writer, vanishingly rare) lock before
    /// surfacing `SQLITE_BUSY`.
    ///
    /// Generous on purpose: a draft must not be dropped on momentary contention.
    private static let busyTimeout: TimeInterval = 5

    /// Bounded `open` attempts when a healthy file is momentarily locked. `busyMode`
    /// already waits `busyTimeout` per attempt, so this is belt-and-suspenders.
    private static let maxOpenAttempts = 3

    private let databaseQueue: DatabaseQueue

    /// Opens or creates a file-backed draft store at `path`, applying migrations.
    ///
    /// - Parameter path: The on-disk location of `drafts.sqlite`. Created on first
    ///   run. Prefer `open(at:)`, which adds lock-retry and corrupt-quarantine.
    /// - Throws: A `DatabaseError` if the file can't be opened or migrated.
    public init(path: String) throws {
        var configuration = Configuration()
        // A draft must not be dropped on momentary contention; wait generously
        // (single-writer, so this effectively never trips).
        configuration.busyMode = .timeout(Self.busyTimeout)
        // Pin synchronous = FULL explicitly: precious data must not inherit a
        // SQLite/GRDB default a future upgrade could relax. Each commit fsyncs.
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        try self.init(
            databaseQueue: DatabaseQueue(path: path, configuration: configuration)
        )
    }

    /// Creates an ephemeral in-memory store for tests and previews ONLY.
    ///
    /// Never used in production: a volatile store would silently lose the user's
    /// drafts, the exact failure this store exists to prevent.
    public static func inMemory() throws -> StowerDraftStore {
        try StowerDraftStore(databaseQueue: DatabaseQueue())
    }

    private init(databaseQueue: DatabaseQueue) throws {
        try Self.migrate(databaseQueue)
        self.databaseQueue = databaseQueue
    }

    /// The default store location under `Application Support/Stower/drafts.sqlite`.
    ///
    /// `nil` only when Application Support itself cannot be resolved or created — a
    /// disk-level failure the caller surfaces, never papers over.
    public static var defaultURL: URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return
            base
            .appendingPathComponent("Stower", isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    /// Opens a working on-disk store at `url`, ALWAYS yielding persistence (JC6).
    ///
    /// Precious posture: a transient lock is retried (bounded); a confirmed corrupt
    /// or unopenable file is quarantined aside (renamed `…corrupt-<ts>`, NEVER
    /// deleted) and a fresh store is created in its place. Only a true disk-level
    /// failure (unwritable directory, disk full, or an exhausted lock retry) throws
    /// to the caller. There is NO in-memory fallback: a volatile store would
    /// silently lose drafts.
    ///
    /// - Parameter url: Where `drafts.sqlite` lives (its directory is created).
    /// - Returns: A working, file-backed store at `url`.
    /// - Throws: A disk-level error (unwritable directory, disk full) or
    ///   `StowerDraftStoreError.openFailed` if every lock retry was exhausted.
    public static func open(at url: URL) throws -> StowerDraftStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var lastLockError: Error?
        for _ in 0..<Self.maxOpenAttempts {
            do {
                return try StowerDraftStore(path: url.path)
            } catch let error as DatabaseError where Self.isTransientLock(error) {
                // Healthy file, momentarily busy (busyMode already waited) — retry.
                lastLockError = error
                continue
            } catch let error as DatabaseError where Self.isCorruption(error) {
                // Confirmed corruption: preserve the bytes aside, never delete, and
                // start fresh so persistence is restored without data being erased.
                try Self.quarantine(url)
                return try StowerDraftStore(path: url.path)
            }
        }
        throw lastLockError ?? StowerDraftStoreError.openFailed
    }

    /// Every stored draft, keyed by `draftKey`, carrying body + last-edited time.
    public func all() throws -> [String: StowerDraftRecord] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT draft_key, body, updated_at FROM draft"
            )
            var drafts: [String: StowerDraftRecord] = [:]
            for row in rows {
                let key: String = row["draft_key"]
                drafts[key] = StowerDraftRecord(
                    body: row["body"],
                    updatedAt: row["updated_at"]
                )
            }
            return drafts
        }
    }

    /// Inserts or replaces the draft for `key`; a blank/whitespace body deletes it.
    ///
    /// Write-through and fsync-durable (`synchronous = FULL`): when this returns the
    /// change is on disk. The body is stored verbatim (internal whitespace and
    /// newlines preserved); only an all-whitespace body counts as "no draft" (JC3).
    public func upsert(key: String, body: String) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try deleteRow(key: key)
            return
        }
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO draft (draft_key, body, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(draft_key) DO UPDATE SET
                      body = excluded.body,
                      updated_at = excluded.updated_at
                    """,
                arguments: [key, body, Date()]
            )
        }
    }

    /// Deletes the draft for `key`; a no-op when none exists.
    public func delete(key: String) throws {
        try deleteRow(key: key)
    }

    private func deleteRow(key: String) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: "DELETE FROM draft WHERE draft_key = ?",
                arguments: [key]
            )
        }
    }

    /// Whether the open error is a transient lock (retry resolves it).
    private static func isTransientLock(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED
    }

    /// Whether the open error is confirmed corruption (quarantine, never delete).
    ///
    /// `SQLITE_CORRUPT` is a malformed page; `SQLITE_NOTADB` is a file whose header
    /// is not SQLite at all. A transient lock is never one of these, so a healthy
    /// busy file is never misclassified as corrupt.
    private static func isCorruption(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Renames the unopenable file aside as `…corrupt-<ts>` (never deletes it).
    ///
    /// On a rollback-journaled `DatabaseQueue` there are no `-wal`/`-shm` sidecars,
    /// so only the main file carries the bytes worth preserving for recovery.
    private static func quarantine(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantined =
            url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try FileManager.default.moveItem(at: url, to: quarantined)
    }
}
