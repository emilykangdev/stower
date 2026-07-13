import Foundation

/// A checkpointed, private working copy of the granted `chat.db` (+ sidecars).
///
/// Mirrors `Scripts/inspect-chatdb-shapes.sh`'s copy/checkpoint sequence: `cp`
/// the live database and its `-wal`/`-shm` sidecars into a temp directory,
/// then fold the copied WAL frames in via `PRAGMA journal_mode=DELETE` on the
/// PRIVATE COPY ONLY — the live source is never opened as a database
/// connection, only ever `cp`'d.
internal struct StowerChatDBInspectorCopy {
    internal let rootURL: URL
    internal let databaseURL: URL

    /// Removes the temp directory holding this working copy.
    internal func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// Copies `sourceDatabaseURL` (+ `-wal`/`-shm` siblings, if present) into a
    /// fresh temp directory and checkpoints the copy's WAL frames in-place.
    ///
    /// A copied `chat.db` holds real message content, so a failure partway
    /// through (e.g. a sidecar copy throwing after the database itself
    /// copied) must not leave that copy behind in `/tmp` — every throwing
    /// step removes `root` before rethrowing (Codex P2 finding).
    internal static func makeCheckpointedCopy(
        of sourceDatabaseURL: URL
    ) throws -> StowerChatDBInspectorCopy {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "stower-chatdb-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let destination = try copyDatabaseAndSidecars(
                from: sourceDatabaseURL,
                into: root,
                fileManager: fileManager
            )
            checkpointIfNeeded(at: destination, fileManager: fileManager)
            return StowerChatDBInspectorCopy(rootURL: root, databaseURL: destination)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    /// Copies the database file and its `-wal`/`-shm` siblings (if present)
    /// into `root`, returning the copied database's URL.
    private static func copyDatabaseAndSidecars(
        from sourceDatabaseURL: URL,
        into root: URL,
        fileManager: FileManager
    ) throws -> URL {
        let destination = root.appendingPathComponent(sourceDatabaseURL.lastPathComponent)
        try fileManager.copyItem(at: sourceDatabaseURL, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: sourceDatabaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceSidecar.path) else { continue }
            let destinationSidecar = URL(fileURLWithPath: destination.path + suffix)
            try fileManager.copyItem(at: sourceSidecar, to: destinationSidecar)
        }
        return destination
    }

    /// Folds copied WAL frames into `destination` before querying.
    ///
    /// An immutable/read-only open of a WAL-mode database does not replay the
    /// WAL, so un-checkpointed recent rows would be silently omitted from
    /// every count otherwise. A checkpoint failure isn't fatal (the bash
    /// original only warned, never aborted), but it must not vanish silently.
    private static func checkpointIfNeeded(at destination: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: destination.path + "-wal") else { return }
        do {
            _ = try StowerChatDBInspectorSQLite.execute(
                databasePath: destination.path,
                sql: "PRAGMA journal_mode=DELETE;"
            )
        } catch {
            FileHandle.standardError.write(
                Data("WARNING: could not checkpoint the copied WAL; very recent rows may ".utf8)
            )
            FileHandle.standardError.write(Data("be omitted from the counts below.\n".utf8))
        }
    }
}
