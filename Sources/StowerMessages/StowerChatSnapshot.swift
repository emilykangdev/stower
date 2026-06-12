import Foundation
import GRDB

internal final class StowerChatSnapshot {
    internal let databaseURL: URL
    internal let openedReadonly: Bool

    private let rootURL: URL
    private let databaseQueue: DatabaseQueue
    private let fileManager: FileManager

    internal init(
        sourceURL: URL,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) throws {
        self.fileManager = fileManager
        let temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        // Best-effort housekeeping; a sweep failure must never block reading.
        try? Self.sweepStaleSnapshots(in: temporaryDirectory, fileManager: fileManager)
        let snapshot = try Self.makeValidatedSnapshot(
            sourceURL: sourceURL,
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )
        rootURL = snapshot.rootURL
        databaseURL = snapshot.databaseURL
        databaseQueue = snapshot.databaseQueue
        openedReadonly = true
    }

    deinit {
        // Intentional best-effort cleanup: deinit cannot throw, and
        // sweepStaleSnapshots reclaims anything left behind on the next run.
        try? fileManager.removeItem(at: rootURL)
    }

    internal func ingestRows(
        since date: Date
    ) throws -> (rows: [StowerSourceMessageRow], participants: [Int64: [String]]) {
        try databaseQueue.read { database in
            let rows = try StowerMessageQuery.ingestRows(database: database, since: date)
            let chatIDs = Set(rows.map(\.chat.rowID))
            let participants = try StowerMessageQuery.participants(
                database: database,
                chatRowIDs: chatIDs
            )
            return (rows, participants)
        }
    }

    internal func recentRows(
        chatID: String,
        limit: Int
    ) throws -> (rows: [StowerSourceMessageRow], participants: [Int64: [String]]) {
        try databaseQueue.read { database in
            let rows = try StowerMessageQuery.recentRows(
                database: database,
                chatID: chatID,
                limit: limit
            )
            let chatIDs = Set(rows.map(\.chat.rowID))
            let participants = try StowerMessageQuery.participants(
                database: database,
                chatRowIDs: chatIDs
            )
            return (rows, participants)
        }
    }

    private static func makeValidatedSnapshot(
        sourceURL: URL,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws -> SnapshotComponents {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StowerMessagesError.sourceNotFound(sourceURL.path)
        }
        // Messages.app may checkpoint the live DB mid-copy, producing a torn
        // snapshot; one retry recovers that transient state.
        var lastValidationError: Error = StowerMessagesError.invalidSnapshot
        for _ in 0..<2 {
            do {
                let copiedURL = try copySource(
                    sourceURL: sourceURL,
                    temporaryDirectory: temporaryDirectory,
                    fileManager: fileManager
                )
                do {
                    return try openValidated(rootURL: copiedURL, fileManager: fileManager)
                } catch {
                    lastValidationError = error
                    try? fileManager.removeItem(at: copiedURL)
                }
            } catch {
                throw classify(error, sourceURL: sourceURL)
            }
        }
        if let messagesError = lastValidationError as? StowerMessagesError {
            throw messagesError
        }
        throw StowerMessagesError.unreadableSource(lastValidationError.localizedDescription)
    }

    private static func copySource(
        sourceURL: URL,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let stagingURL = temporaryDirectory.appendingPathComponent(
            "stower-msg-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        let finalURL = temporaryDirectory.appendingPathComponent(
            "stower-msg-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        do {
            try copyDatabaseFiles(
                sourceURL: sourceURL,
                destinationDirectory: stagingURL,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            return finalURL
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private static func copyDatabaseFiles(
        sourceURL: URL,
        destinationDirectory: URL,
        fileManager: FileManager
    ) throws {
        let destination = destinationDirectory.appendingPathComponent("chat.db")
        try fileManager.copyItem(at: sourceURL, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceSidecar.path) else {
                continue
            }
            let destinationSidecar = URL(fileURLWithPath: destination.path + suffix)
            try fileManager.copyItem(at: sourceSidecar, to: destinationSidecar)
        }
    }

    private static func openValidated(
        rootURL: URL,
        fileManager: FileManager
    ) throws -> SnapshotComponents {
        let databaseURL = rootURL.appendingPathComponent("chat.db")
        try recoverWriteAheadLog(at: databaseURL)
        var configuration = Configuration()
        configuration.readonly = true
        let databaseQueue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: configuration
        )
        let check = try databaseQueue.read { database in
            try String.fetchAll(database, sql: "PRAGMA quick_check")
        }
        guard check == ["ok"] else {
            try? fileManager.removeItem(at: rootURL)
            throw StowerMessagesError.invalidSnapshot
        }
        return SnapshotComponents(
            rootURL: rootURL,
            databaseURL: databaseURL,
            databaseQueue: databaseQueue
        )
    }

    /// Folds copied WAL frames into the private snapshot before read-only use.
    ///
    /// A raw file copy of a WAL-mode database needs recovery and shared-memory
    /// setup, which SQLite refuses on read-only connections. Switching the
    /// private copy back to a rollback journal checkpoints every WAL frame,
    /// deletes the sidecar files, and rewrites the header, so the read-only
    /// open sees a self-contained database. The original Source DB is never
    /// touched.
    private static func recoverWriteAheadLog(at databaseURL: URL) throws {
        let recoveryQueue = try DatabaseQueue(path: databaseURL.path)
        try recoveryQueue.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA journal_mode=DELETE")
        }
        try recoveryQueue.close()
    }

    private static func sweepStaleSnapshots(
        in temporaryDirectory: URL,
        fileManager: FileManager
    ) throws {
        let cutoff = Date().addingTimeInterval(-86_400)
        let contents = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in contents where url.lastPathComponent.hasPrefix("stower-msg-") {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values.contentModificationDate, modified < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    internal static func classify(_ error: Error, sourceURL: URL) -> StowerMessagesError {
        if permissionDenialImplicatesSource(error, sourceURL: sourceURL) {
            return .fullDiskAccessMissing(sourceURL.path)
        }
        return .unreadableSource((error as NSError).localizedDescription)
    }

    /// Reports whether a permission denial in the error chain is attributable to
    /// the source database rather than the staging destination.
    ///
    /// `classify` sees failures from the whole copy pipeline — staging
    /// `createDirectory`, the source `copyItem`, and the `moveItem` into place —
    /// so an unwritable `temporaryDirectory` also surfaces EACCES/EPERM. Full
    /// Disk Access is only the right diagnosis when the denied path is the source
    /// DB (or a source sidecar), or when the denial carries no path to attribute
    /// at all. A denial that names only a destination path is a staging-write
    /// failure, not a TCC denial on `chat.db`.
    private static func permissionDenialImplicatesSource(
        _ error: Error,
        sourceURL: URL
    ) -> Bool {
        let sourcePaths = sourcePathSet(for: sourceURL)
        var sawDenial = false
        var sawDestinationDenial = false
        var current: NSError? = error as NSError
        while let nsError = current {
            if isPOSIXDenial(nsError) || isCocoaDenial(nsError) {
                sawDenial = true
                if let path = deniedPath(in: nsError) {
                    if sourcePaths.contains(path) {
                        return true
                    }
                    sawDestinationDenial = true
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return sawDenial && !sawDestinationDenial
    }

    /// The source DB path plus its WAL/SHM sidecars, normalized for comparison
    /// against the path Cocoa records on a file error.
    private static func sourcePathSet(for sourceURL: URL) -> Set<String> {
        let base = sourceURL.path
        return Set([base, base + "-wal", base + "-shm"].map(normalizedPath))
    }

    /// The file path a Cocoa/POSIX error blames, if any, normalized for comparison.
    private static func deniedPath(in error: NSError) -> String? {
        if let path = error.userInfo[NSFilePathErrorKey] as? String {
            return normalizedPath(path)
        }
        if let url = error.userInfo[NSURLErrorKey] as? URL {
            return normalizedPath(url.path)
        }
        return nil
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isPOSIXDenial(_ error: NSError) -> Bool {
        error.domain == NSPOSIXErrorDomain
            && (error.code == Int(EACCES) || error.code == Int(EPERM))
    }

    private static func isCocoaDenial(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoPermissionError
                || error.code == NSFileWriteNoPermissionError)
    }
}

private struct SnapshotComponents {
    fileprivate let rootURL: URL
    fileprivate let databaseURL: URL
    fileprivate let databaseQueue: DatabaseQueue
}
