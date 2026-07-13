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
    internal static func makeCheckpointedCopy(
        of sourceDatabaseURL: URL
    ) throws -> StowerChatDBInspectorCopy {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "stower-chatdb-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(sourceDatabaseURL.lastPathComponent)
        try fileManager.copyItem(at: sourceDatabaseURL, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: sourceDatabaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceSidecar.path) else { continue }
            let destinationSidecar = URL(fileURLWithPath: destination.path + suffix)
            try fileManager.copyItem(at: sourceSidecar, to: destinationSidecar)
        }
        // Folding WAL frames in BEFORE querying matters: an immutable/read-only
        // open of a WAL-mode database does not replay the WAL, so un-checkpointed
        // recent rows would be silently omitted from every count otherwise.
        if fileManager.fileExists(atPath: destination.path + "-wal") {
            _ = try? StowerChatDBInspectorSQLite.execute(
                databasePath: destination.path,
                sql: "PRAGMA journal_mode=DELETE;"
            )
        }
        return StowerChatDBInspectorCopy(rootURL: root, databaseURL: destination)
    }
}
