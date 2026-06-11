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
        try Self.sweepStaleSnapshots(in: temporaryDirectory, fileManager: fileManager)
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
                    try? fileManager.removeItem(at: copiedURL)
                }
            } catch {
                throw classify(error, sourceURL: sourceURL)
            }
        }
        throw StowerMessagesError.invalidSnapshot
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
        let nsError = error as NSError
        let isPOSIXPermissionError =
            nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM))
        if isPOSIXPermissionError {
            return .fullDiskAccessMissing(sourceURL.path)
        }
        let isCocoaPermissionError =
            nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileReadNoPermissionError
        if isCocoaPermissionError {
            return .fullDiskAccessMissing(sourceURL.path)
        }
        return .unreadableSource(nsError.localizedDescription)
    }
}

private struct SnapshotComponents {
    fileprivate let rootURL: URL
    fileprivate let databaseURL: URL
    fileprivate let databaseQueue: DatabaseQueue
}
