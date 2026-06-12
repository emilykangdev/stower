import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerChatSnapshot")
internal struct StowerChatSnapshotTests {
    @Test("copies the source, opens readonly, and leaves source bytes unchanged")
    internal func readonlyCopy() throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let originalData = try Data(contentsOf: fixture.databaseURL)
        let originalDate = try modificationDate(fixture.databaseURL)
        let temp = fixture.rootURL.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        var snapshot: StowerChatSnapshot? = try StowerChatSnapshot(
            sourceURL: fixture.databaseURL,
            temporaryDirectory: temp
        )
        let copiedURL = try #require(snapshot?.databaseURL)

        #expect(snapshot?.openedReadonly == true)
        #expect(copiedURL != fixture.databaseURL)
        #expect(try Data(contentsOf: fixture.databaseURL) == originalData)
        #expect(try modificationDate(fixture.databaseURL) == originalDate)

        snapshot = nil
        #expect(!FileManager.default.fileExists(atPath: copiedURL.deletingLastPathComponent().path))
    }

    @Test("recovers WAL frames copied from a live database")
    internal func walRecovery() throws {
        let fixture = try StowerFixtureDatabase(useWriteAheadLog: true)
        defer { fixture.remove() }
        let walURL = URL(fileURLWithPath: fixture.databaseURL.path + "-wal")
        let originalWALData = try Data(contentsOf: walURL)
        #expect(!originalWALData.isEmpty)

        let snapshot = try StowerChatSnapshot(sourceURL: fixture.databaseURL)
        let source = try snapshot.ingestRows(since: .distantPast)

        #expect(snapshot.openedReadonly)
        #expect(source.rows.contains(where: { $0.guid == "newest" }))
        #expect(try Data(contentsOf: walURL) == originalWALData)
    }

    @Test("rejects an invalid SQLite copy after retrying")
    internal func invalidCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stower-invalid-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chat.db")
        try Data("not sqlite".utf8).write(to: source)

        #expect(throws: StowerMessagesError.self) {
            _ = try StowerChatSnapshot(sourceURL: source, temporaryDirectory: root)
        }
    }

    @Test("classifies permission failures as missing Full Disk Access")
    internal func permissionClassification() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let classified = StowerChatSnapshot.classify(
            error,
            sourceURL: URL(fileURLWithPath: "/fixture/chat.db")
        )

        guard case .fullDiskAccessMissing = classified else {
            Issue.record("Expected a Full Disk Access error.")
            return
        }
    }

    @Test("classifies a copy denial with a nested POSIX error as missing Full Disk Access")
    internal func wrappedCopyPermissionClassification() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let copyDenied = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: posix]
        )
        let classified = StowerChatSnapshot.classify(
            copyDenied,
            sourceURL: URL(fileURLWithPath: "/fixture/chat.db")
        )

        guard case .fullDiskAccessMissing = classified else {
            Issue.record("Expected a Full Disk Access error for the wrapped copy denial.")
            return
        }
    }

    @Test("reports an unwritable staging directory as unreadableSource, not Full Disk Access")
    internal func unwritableStagingIsNotFullDiskAccess() throws {
        let fixture = try StowerFixtureDatabase()
        defer { fixture.remove() }
        let readonlyRoot = fixture.rootURL.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readonlyRoot, withIntermediateDirectories: true)
        // Strip owner write so staging createDirectory fails with EACCES even
        // though the source DB is perfectly readable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: readonlyRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: readonlyRoot.path
            )
        }

        do {
            _ = try StowerChatSnapshot(
                sourceURL: fixture.databaseURL,
                temporaryDirectory: readonlyRoot
            )
            Issue.record("Expected snapshot creation to fail on a read-only staging directory.")
        } catch let error as StowerMessagesError {
            guard case .unreadableSource = error else {
                Issue.record("Expected unreadableSource for unwritable staging, got \(error).")
                return
            }
        }
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return try #require(values.contentModificationDate)
    }
}
