import Foundation
import GRDB

/// An interaction-event-store open failure with no more specific SQLite cause.
///
/// Thrown only when every bounded open attempt hit a transient lock — a real,
/// surfaced contention failure, not a healthy busy file the retry resolved.
internal enum StowerInteractionEventStoreError: Error, Equatable {
    /// Every bounded open attempt failed on a lock; treated as a real error.
    case openFailed
}

/// Persistent, append-only store of the user's semantic interaction events.
///
/// PRECIOUS append-only data — the same posture as `StowerDraftStore`, the opposite
/// of the disposable `StowerReplyVerdictCache`. The event log is the user's own
/// record of what they did (dismiss / mute / unmute, and later surfaces), which can
/// never be recomputed, so it is NEVER erased to recover: migrations are
/// additive-only (no `eraseIfStale`), and an unopenable file is quarantined aside
/// (renamed `…corrupt-<ts>`, never deleted).
///
/// Runs on a default rollback-journaled `DatabaseQueue` (NOT WAL) and pins
/// `synchronous = FULL`. The v1 API is deliberately tiny — `record` (append) and
/// `recent(limit:)` (read, newest first) for tests and developer inspection only;
/// there is no product surface, export, or analysis here.
public actor StowerInteractionEventStore {
    /// The file name the store owns under `Application Support/Stower`.
    public static let fileName = "interaction_events.sqlite"

    /// How long a write waits on a (single-writer, vanishingly rare) lock before
    /// surfacing `SQLITE_BUSY`.
    private static let busyTimeout: TimeInterval = 5

    /// Bounded `open` attempts when a healthy file is momentarily locked.
    private static let maxOpenAttempts = 3

    private let databaseQueue: DatabaseQueue

    /// Opens or creates a file-backed event store at `path`, applying migrations.
    ///
    /// - Parameter path: The on-disk location of `interaction_events.sqlite`. Created
    ///   on first run. Prefer `open(at:)`, which adds lock-retry and quarantine.
    /// - Throws: A `DatabaseError` if the file can't be opened or migrated.
    public init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(Self.busyTimeout)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        try self.init(
            databaseQueue: DatabaseQueue(path: path, configuration: configuration)
        )
    }

    /// Creates an ephemeral in-memory store for tests ONLY.
    public static func inMemory() throws -> StowerInteractionEventStore {
        try StowerInteractionEventStore(databaseQueue: DatabaseQueue())
    }

    private init(databaseQueue: DatabaseQueue) throws {
        try Self.migrate(databaseQueue)
        self.databaseQueue = databaseQueue
    }

    /// The default location under `Application Support/Stower/interaction_events.sqlite`.
    ///
    /// `nil` only when Application Support itself cannot be resolved or created.
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

    /// Opens a working on-disk store at `url`, ALWAYS yielding persistence.
    ///
    /// Precious posture identical to `StowerDraftStore`: retry a transient lock,
    /// quarantine a confirmed-corrupt file aside (never delete), recreate fresh. Only
    /// a true disk-level failure or an exhausted lock retry throws.
    ///
    /// - Parameter url: Where `interaction_events.sqlite` lives (dir is created).
    /// - Returns: A working, file-backed store at `url`.
    /// - Throws: A disk-level error or `StowerInteractionEventStoreError.openFailed`.
    public static func open(at url: URL) throws -> StowerInteractionEventStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var lastLockError: Error?
        for _ in 0..<Self.maxOpenAttempts {
            do {
                return try StowerInteractionEventStore(path: url.path)
            } catch let error as DatabaseError where Self.isTransientLock(error) {
                lastLockError = error
                continue
            } catch let error as DatabaseError where Self.isCorruption(error) {
                try Self.quarantine(url)
                return try StowerInteractionEventStore(path: url.path)
            }
        }
        throw lastLockError ?? StowerInteractionEventStoreError.openFailed
    }

    /// Appends one event, stamping the current `StowerInteractionEvent.schemaVersion`.
    public func record(_ event: StowerInteractionEvent) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO interaction_event
                      (eventType, occurredAt, actor, surface, handleKey, messageGUID,
                       draftKey, boardTab, metadataJSON, schemaVersion)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.eventType, event.occurredAt, event.actor, event.surface,
                    event.handleKey, event.messageGUID, event.draftKey, event.boardTab,
                    event.metadataJSON, StowerInteractionEvent.schemaVersion
                ]
            )
        }
    }

    /// The most recent `limit` events, NEWEST FIRST (descending insert order).
    ///
    /// For tests and developer inspection only — there is no product reader in v1.
    public func recent(limit: Int) throws -> [StowerInteractionEvent] {
        try databaseQueue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT eventType, occurredAt, actor, surface, handleKey, messageGUID,
                           draftKey, boardTab, metadataJSON
                    FROM interaction_event
                    ORDER BY id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            ).map { row in
                StowerInteractionEvent(
                    eventType: row["eventType"],
                    occurredAt: row["occurredAt"],
                    actor: row["actor"],
                    surface: row["surface"],
                    handleKey: row["handleKey"],
                    messageGUID: row["messageGUID"],
                    draftKey: row["draftKey"],
                    boardTab: row["boardTab"],
                    metadataJSON: row["metadataJSON"]
                )
            }
        }
    }

    // MARK: - Open / quarantine (mirrors StowerDraftStore)

    private static func isTransientLock(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED
    }

    private static func isCorruption(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    private static func quarantine(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantined =
            url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try FileManager.default.moveItem(at: url, to: quarantined)
    }
}
