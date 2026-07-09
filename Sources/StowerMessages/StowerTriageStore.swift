import Foundation
import GRDB

/// A triage-store open failure with no more specific SQLite cause.
///
/// Thrown only when every bounded open attempt hit a transient lock — a real,
/// surfaced contention failure, not a healthy busy file the retry resolved.
internal enum StowerTriageStoreError: Error, Equatable {
    /// Every bounded open attempt failed on a lock; treated as a real error.
    case openFailed
}

/// Persistent, handle-keyed store of the user's board-triage intent: which single
/// messages they dismissed and which contacts they muted.
///
/// PRECIOUS, app-owned data — the same posture as `StowerDraftStore`, the opposite
/// of the disposable `StowerReplyVerdictCache`. A mute ("don't show me this person")
/// and a dismiss ("not this message") are user intent that cannot be recomputed, so
/// they are NEVER erased to recover: migrations are additive-only (no
/// `eraseIfStale`), and an unopenable file is quarantined aside (renamed
/// `…corrupt-<ts>`, never deleted) so the bytes survive for recovery.
///
/// Keyed by the conversation's normalized handle (`StowerDraftKey`) so triage is
/// immune to chat-GUID churn and SMS<->iMessage flips. It runs on a default
/// rollback-journaled `DatabaseQueue` (NOT WAL — no `-wal`/`-shm` sidecars) and pins
/// `synchronous = FULL` so every committed change is fsync-durable.
///
/// Four tables: `dismissed_message` + `muted_contact` are bounded current state (one
/// row per person); `dismissal_history` + `muted_contact_history` are append-only
/// logs (the PAR-32 / interaction-memory training substrate) with no hot-path reader.
public actor StowerTriageStore {
    /// The file name the store owns under `Application Support/Stower`.
    public static let fileName = "triage.sqlite"

    /// The `muted_contact_history.event` token for a mute.
    private static let mutedEvent = "muted"

    /// The `muted_contact_history.event` token for an unmute.
    private static let unmutedEvent = "unmuted"

    /// How long a write waits on a (single-writer, vanishingly rare) lock before
    /// surfacing `SQLITE_BUSY`.
    ///
    /// Generous on purpose: triage intent must not be dropped on momentary contention.
    private static let busyTimeout: TimeInterval = 5

    /// Bounded `open` attempts when a healthy file is momentarily locked.
    private static let maxOpenAttempts = 3

    private let databaseQueue: DatabaseQueue

    /// Opens or creates a file-backed triage store at `path`, applying migrations.
    ///
    /// - Parameter path: The on-disk location of `triage.sqlite`. Created on first
    ///   run. Prefer `open(at:)`, which adds lock-retry and corrupt-quarantine.
    /// - Throws: A `DatabaseError` if the file can't be opened or migrated.
    public init(path: String) throws {
        var configuration = Configuration()
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

    /// Creates an ephemeral in-memory store for tests ONLY.
    ///
    /// Never used in production: a volatile store would silently lose the user's
    /// triage intent, the exact failure this store exists to prevent.
    public static func inMemory() throws -> StowerTriageStore {
        try StowerTriageStore(databaseQueue: DatabaseQueue())
    }

    private init(databaseQueue: DatabaseQueue) throws {
        try Self.migrate(databaseQueue)
        self.databaseQueue = databaseQueue
    }

    /// The default store location under `Application Support/<folderName>/triage.sqlite`.
    ///
    /// `nil` when Application Support itself cannot be resolved or created — a
    /// disk-level failure the caller surfaces, never papers over — or when
    /// `folderName` is not a single, safe path component (empty, contains `/`,
    /// or is `.`/`..`).
    ///
    /// - Parameter folderName: The build-variant Application Support subfolder
    ///   (e.g. `"Stower"`, `"StowerDebug"`), supplied by the caller so this
    ///   engine-side type never has to know about `StowerEnvironment` itself.
    /// - Returns: The resolved `triage.sqlite` URL, or `nil` per the cases above.
    public static func defaultURL(inFolder folderName: String) -> URL? {
        guard !folderName.isEmpty, !folderName.contains("/"), folderName != "..", folderName != "."
        else {
            return nil
        }
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
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    /// Opens a working on-disk store at `url`, ALWAYS yielding persistence.
    ///
    /// Precious posture: a transient lock is retried (bounded); a confirmed corrupt
    /// or unopenable file is quarantined aside (renamed `…corrupt-<ts>`, NEVER
    /// deleted) and a fresh store is created in its place. Only a true disk-level
    /// failure (unwritable directory, disk full, or an exhausted lock retry) throws.
    /// There is NO in-memory fallback: a volatile store would silently lose triage.
    ///
    /// - Parameter url: Where `triage.sqlite` lives (its directory is created).
    /// - Returns: A working, file-backed store at `url`.
    /// - Throws: A disk-level error (unwritable directory, disk full); the underlying
    ///   `DatabaseError` (the last `SQLITE_BUSY`/`LOCKED`) when every lock retry is
    ///   exhausted; or `StowerTriageStoreError.openFailed` only as a fallback when no
    ///   specific lock error was captured.
    public static func open(at url: URL) throws -> StowerTriageStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var lastLockError: Error?
        for _ in 0..<Self.maxOpenAttempts {
            do {
                return try StowerTriageStore(path: url.path)
            } catch let error as DatabaseError where Self.isTransientLock(error) {
                lastLockError = error
                continue
            } catch let error as DatabaseError where Self.isCorruption(error) {
                try Self.quarantine(url)
                return try StowerTriageStore(path: url.path)
            }
        }
        throw lastLockError ?? StowerTriageStoreError.openFailed
    }

    // MARK: - Reads (the board filter's hot path)

    /// Every active dismissal, keyed by `handleKey` (one row per person).
    public func dismissedMessages() throws -> [String: StowerDismissedMessageRecord] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT handleKey, messageGUID, anchorTimestamp FROM dismissed_message"
            )
            var dismissals: [String: StowerDismissedMessageRecord] = [:]
            for row in rows {
                let key: String = row["handleKey"]
                let anchorSeconds: Double = row["anchorTimestamp"]
                dismissals[key] = StowerDismissedMessageRecord(
                    messageGUID: row["messageGUID"],
                    anchorTimestamp: Date(timeIntervalSinceReferenceDate: anchorSeconds)
                )
            }
            return dismissals
        }
    }

    /// Every muted contact (one row per muted handle).
    public func muted() throws -> [StowerMutedContactRecord] {
        try databaseQueue.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT handleKey, mutedAt FROM muted_contact"
            ).map { row in
                StowerMutedContactRecord(handleKey: row["handleKey"], mutedAt: row["mutedAt"])
            }
        }
    }

    // MARK: - Dismiss lifecycle

    /// Dismisses (or re-dismisses) a person's current last act — upsert by `handleKey`.
    ///
    /// One row per person: a new dismiss for someone who already has a row overwrites
    /// the anchor in place (never a second row), so the table is bounded by contact
    /// count, not message count.
    public func dismiss(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        dismissedAt: Date
    ) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO dismissed_message
                      (handleKey, messageGUID, anchorTimestamp, dismissedAt)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(handleKey) DO UPDATE SET
                      messageGUID = excluded.messageGUID,
                      anchorTimestamp = excluded.anchorTimestamp,
                      dismissedAt = excluded.dismissedAt
                    """,
                arguments: [
                    handleKey, messageGUID, anchorTimestamp.timeIntervalSinceReferenceDate,
                    dismissedAt
                ]
            )
        }
    }

    /// Reverses a dismissal (undo / ⌘Z): deletes the active row, logs NOTHING.
    ///
    /// An undo repudiates the dismissal, so it must leave no trace in
    /// `dismissal_history` — only dismissals that stuck until a newer message retired
    /// them are training signal.
    public func undismiss(handleKey: String) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: "DELETE FROM dismissed_message WHERE handleKey = ?",
                arguments: [handleKey]
            )
        }
    }

    /// Retires a dismissal a strictly-newer message superseded — a guarded MOVE.
    ///
    /// One transaction: copy the matching active row into `dismissal_history` with a
    /// `retiredAt` stamp, then delete it. IDEMPOTENT + GUARDED — the copy matches on
    /// `handleKey` + `messageGUID` + `anchorTimestamp`, so a second (stale, concurrent)
    /// load that already moved the row, or a newer dismiss that replaced it, matches
    /// ZERO rows and is a clean no-op (no duplicate, no half-written history row).
    public func retireDismissal(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        retiredAt: Date
    ) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO dismissal_history
                      (handleKey, messageGUID, anchorTimestamp, dismissedAt, retiredAt)
                    SELECT handleKey, messageGUID, anchorTimestamp, dismissedAt, ?
                    FROM dismissed_message
                    WHERE handleKey = ? AND messageGUID = ? AND anchorTimestamp = ?
                    """,
                arguments: [
                    retiredAt, handleKey, messageGUID,
                    anchorTimestamp.timeIntervalSinceReferenceDate
                ]
            )
            try database.execute(
                sql: """
                    DELETE FROM dismissed_message
                    WHERE handleKey = ? AND messageGUID = ? AND anchorTimestamp = ?
                    """,
                arguments: [
                    handleKey, messageGUID, anchorTimestamp.timeIntervalSinceReferenceDate
                ]
            )
        }
    }

    // MARK: - Mute lifecycle

    /// Mutes (or re-mutes) a contact: upsert `muted_contact` + append a `'muted'`
    /// event to `muted_contact_history`.
    ///
    /// `muted_contact` keeps at most one active row per handle; every mute still
    /// appends to the history log (the local mute/unmute training signal).
    public func mute(handleKey: String, mutedAt: Date) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO muted_contact (handleKey, mutedAt)
                    VALUES (?, ?)
                    ON CONFLICT(handleKey) DO UPDATE SET mutedAt = excluded.mutedAt
                    """,
                arguments: [handleKey, mutedAt]
            )
            try Self.appendMuteEvent(
                database,
                handleKey: handleKey,
                event: Self.mutedEvent,
                at: mutedAt
            )
        }
    }

    /// Unmutes a contact: delete `muted_contact` + append an `'unmuted'` event to
    /// `muted_contact_history` (append-only; the history is never mutated or deleted).
    public func unmute(handleKey: String, unmutedAt: Date) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: "DELETE FROM muted_contact WHERE handleKey = ?",
                arguments: [handleKey]
            )
            try Self.appendMuteEvent(
                database,
                handleKey: handleKey,
                event: Self.unmutedEvent,
                at: unmutedAt
            )
        }
    }

    private static func appendMuteEvent(
        _ database: Database,
        handleKey: String,
        event: String,
        at: Date
    ) throws {
        try database.execute(
            sql: "INSERT INTO muted_contact_history (handleKey, event, at) VALUES (?, ?, ?)",
            arguments: [handleKey, event, at]
        )
    }

    // MARK: - Open / quarantine (mirrors StowerDraftStore)

    /// Whether the open error is a transient lock (retry resolves it).
    private static func isTransientLock(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED
    }

    /// Whether the open error is confirmed corruption (quarantine, never delete).
    private static func isCorruption(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Renames the unopenable file aside as `…corrupt-<ts>` (never deletes it).
    private static func quarantine(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantined =
            url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try FileManager.default.moveItem(at: url, to: quarantined)
    }
}
