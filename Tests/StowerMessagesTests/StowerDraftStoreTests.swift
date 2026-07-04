import Foundation
import GRDB
import Testing

@testable import StowerMessages

/// The precious draft store's durability and recovery invariants: additive
/// migrations never erase (I-Precious), `open` always yields an on-disk store for
/// first run and after corruption (I-AlwaysOnDisk), a corrupt file is quarantined
/// aside with its bytes intact rather than deleted (I-CorruptQuarantinedNotDeleted),
/// first run creates the file (I-FirstRunCreates), an upsert survives reopen
/// (I-Durable), and a blank body clears the row (I-EmptyClears).
@Suite("StowerDraftStore")
internal struct StowerDraftStoreTests {
    /// A fresh temp directory the test owns and cleans up.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: I-Durable — an upserted draft survives release + reopen

    @Test("an upserted draft is readable after release and reopen (I-Durable)")
    internal func upsertSurvivesReopen() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(StowerDraftStore.fileName).path

        do {
            let store = try StowerDraftStore(path: path)
            try await store.upsert(key: "e164:15551234567", body: "call mom back")
        }

        let reopened = try StowerDraftStore(path: path)
        #expect(try await reopened.all()["e164:15551234567"]?.body == "call mom back")
    }

    // MARK: I-FirstRunCreates — open at a fresh path creates the file

    @Test("open at a non-existent path creates a working store (I-FirstRunCreates)")
    internal func firstRunCreates() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A nested, not-yet-created subdirectory: open must create the directory too.
        let url =
            directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent(StowerDraftStore.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        let store = try StowerDraftStore.open(at: url)
        try await store.upsert(key: "raw:chat99", body: "hi")

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await store.all()["raw:chat99"]?.body == "hi")
    }

    // MARK: I-AlwaysOnDisk — open yields persistence on first run AND after corruption

    @Test("open persists on first run and again after corruption (I-AlwaysOnDisk)")
    internal func openAlwaysOnDisk() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerDraftStore.fileName)

        // First run: write, reopen, present.
        let first = try StowerDraftStore.open(at: url)
        try await first.upsert(key: "raw:a", body: "alpha")
        let firstReopen = try StowerDraftStore.open(at: url)
        #expect(try await firstReopen.all()["raw:a"]?.body == "alpha")

        // Corrupt the file, then open: a fresh on-disk store, and writes persist.
        try Data("not a database".utf8).write(to: url)
        let afterCorruption = try StowerDraftStore.open(at: url)
        try await afterCorruption.upsert(key: "raw:b", body: "beta")
        let afterReopen = try StowerDraftStore.open(at: url)
        #expect(try await afterReopen.all()["raw:b"]?.body == "beta")
    }

    // MARK: I-CorruptQuarantinedNotDeleted — corrupt bytes preserved aside, never deleted

    @Test("open over a corrupt file quarantines the bytes aside (I-CorruptQuarantinedNotDeleted)")
    internal func corruptFileQuarantinedNotDeleted() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerDraftStore.fileName)
        let garbage = Data("this is not a sqlite database".utf8)
        try garbage.write(to: url)

        let store = try StowerDraftStore.open(at: url)

        // The original bytes survive aside under a `…corrupt-<ts>` name (NOT deleted).
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let quarantined = siblings.filter { $0.hasPrefix("\(StowerDraftStore.fileName).corrupt-") }
        #expect(quarantined.count == 1)
        if let name = quarantined.first {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(bytes == garbage)
        }

        // The path itself is a working store.
        try await store.upsert(key: "raw:c", body: "gamma")
        let reopened = try StowerDraftStore.open(at: url)
        #expect(try await reopened.all()["raw:c"]?.body == "gamma")
    }

    // MARK: I-EmptyClears — a blank/whitespace body deletes the row

    @Test("a blank or whitespace body clears the draft (I-EmptyClears)")
    internal func blankBodyClears() async throws {
        let store = try StowerDraftStore.inMemory()
        try await store.upsert(key: "raw:d", body: "hi")
        #expect(try await store.all()["raw:d"]?.body == "hi")

        try await store.upsert(key: "raw:d", body: "   \n ")
        #expect(try await store.all()["raw:d"] == nil)
    }

    // MARK: I-Precious — a FUTURE additive migration preserves existing drafts
    //
    // Distinct from `StowerDraftStoreSchemaTests`' I5 (which proves the real
    // v1→v2-resolved-at migration itself): this proves the store's additive-only
    // POSTURE holds for a hypothetical NEXT bump layered on top of today's real
    // schema (v1 + v2-resolved-at already applied via `open`), so a future schema
    // change can trust the same guarantee.

    @Test("a future additive migration preserves an existing draft (I-Precious)")
    internal func additiveMigrationPreservesDrafts() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerDraftStore.fileName)
        let path = url.path

        let original = try StowerDraftStore.open(at: url)
        try await original.upsert(key: "email:foo@x.com", body: "draft worth keeping")

        // Apply a NEW additive migration out-of-band (a column add), exactly what a
        // future schema bump would do. The existing v1 + v2-resolved-at ids are
        // already applied and so are skipped; only the new hypothetical v3 runs.
        var migrator = DatabaseMigrator()
        migrator.registerMigration("stower-drafts-v1") { _ in
            // Already applied on this file; registered so the migrator agrees on
            // history. Never re-run.
        }
        migrator.registerMigration("stower-drafts-v2-resolved-at") { _ in
            // Already applied on this file (via `open`); registered so the
            // migrator agrees on history. Never re-run.
        }
        migrator.registerMigration("stower-drafts-v3-hypothetical") { database in
            try database.alter(table: "draft") { table in
                table.add(column: "pinned", .boolean)
            }
        }
        let raw = try DatabaseQueue(path: path)
        try migrator.migrate(raw)

        // The store reopens cleanly and the draft is intact — no erase on bump.
        let reopened = try StowerDraftStore(path: path)
        #expect(try await reopened.all()["email:foo@x.com"]?.body == "draft worth keeping")
    }

    // MARK: I1 — markSent keeps the body and sets resolved_at; never deletes

    @Test("markSent keeps the body and sets resolved_at (I1)")
    internal func markSentKeepsBodyAndSetsResolvedAt() async throws {
        let store = try StowerDraftStore.inMemory()
        try await store.upsert(key: "raw:e", body: "call back")

        try await store.markSent(key: "raw:e")

        let record = try await store.all()["raw:e"]
        #expect(record?.body == "call back")
        #expect(record?.resolvedAt != nil)
    }

    // MARK: I2 — a body upsert clears resolved_at (reactivates)

    @Test("a body upsert clears resolved_at, reactivating the draft (I2)")
    internal func upsertReactivatesResolvedDraft() async throws {
        let store = try StowerDraftStore.inMemory()
        try await store.upsert(key: "raw:f", body: "call back")
        try await store.markSent(key: "raw:f")
        #expect(try await store.all()["raw:f"]?.resolvedAt != nil)

        try await store.upsert(key: "raw:f", body: "new text")

        #expect(try await store.all()["raw:f"]?.resolvedAt == nil)
    }

    // MARK: I3 — blank body still deletes even when resolved_at is set

    @Test("a blank body still deletes a resolved draft (I3)")
    internal func blankBodyDeletesResolvedDraft() async throws {
        let store = try StowerDraftStore.inMemory()
        try await store.upsert(key: "raw:g", body: "call back")
        try await store.markSent(key: "raw:g")

        try await store.upsert(key: "raw:g", body: "   \n ")

        #expect(try await store.all()["raw:g"] == nil)
    }

    // MARK: I4 — all() round-trips resolvedAt (nil and set)

    @Test("all() round-trips resolvedAt for both an active and a resolved draft (I4)")
    internal func allRoundTripsResolvedAt() async throws {
        let store = try StowerDraftStore.inMemory()
        try await store.upsert(key: "raw:active", body: "still drafting")
        try await store.upsert(key: "raw:resolved", body: "already sent")
        try await store.markSent(key: "raw:resolved")

        let drafts = try await store.all()
        #expect(drafts["raw:active"]?.resolvedAt == nil)
        #expect(drafts["raw:resolved"]?.resolvedAt != nil)
    }

    // MARK: I13 — markSent then unmarkSent round-trips (D2 undo)

    @Test(
        "markSent then unmarkSent round-trips: resolved_at clears, body + updated_at intact (I13)"
    )
    internal func markSentThenUnmarkSentRoundTrips() async throws {
        let store = try StowerDraftStore.inMemory()
        try await store.upsert(key: "raw:h", body: "call back")
        let beforeUpdatedAt = try await store.all()["raw:h"]?.updatedAt

        try await store.markSent(key: "raw:h")
        try await store.unmarkSent(key: "raw:h")

        let record = try await store.all()["raw:h"]
        #expect(record?.resolvedAt == nil)
        #expect(record?.body == "call back")
        #expect(record?.updatedAt == beforeUpdatedAt)
    }
}
