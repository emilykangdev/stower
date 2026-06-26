import Foundation
import GRDB
import Testing

@testable import StowerMessages

/// The precious triage store's invariants: dismiss is keyed by handle and upserts
/// (I1); retiring a dismissal is an atomic MOVE (I2); a stale/concurrent retire is an
/// idempotent no-op (I5); every mute/unmute appends to the append-only history while
/// `muted_contact` keeps ≤1 active row (I8); and a version-mismatch reopen never
/// wipes precious intent (I10).
@Suite("StowerTriageStore")
internal struct StowerTriageStoreTests {
    private static let handle = "e164:14155550100"
    private static let other = "e164:14155550199"
    private static let anchor = Date(timeIntervalSince1970: 1_000_000)
    private static let newer = Date(timeIntervalSince1970: 2_000_000)

    /// A fresh temp directory the test owns and cleans up.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-triage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func count(_ table: String, at url: URL) throws -> Int {
        let raw = try DatabaseQueue(path: url.path)
        return try raw.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }

    // MARK: I1 — dismiss is keyed by handle; re-dismiss upserts (≤1 active row)

    @Test("re-dismissing one handle upserts to a single row with the latest GUID (I1)")
    internal func reDismissUpserts() async throws {
        let store = try StowerTriageStore.inMemory()
        try await store.dismiss(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: Self.anchor,
            dismissedAt: Self.anchor
        )
        try await store.dismiss(
            handleKey: Self.handle,
            messageGUID: "g2",
            anchorTimestamp: Self.newer,
            dismissedAt: Self.newer
        )
        let dismissed = try await store.dismissedMessages()
        #expect(dismissed.count == 1)
        #expect(dismissed[Self.handle]?.messageGUID == "g2")
        #expect(dismissed[Self.handle]?.anchorTimestamp == Self.newer)
    }

    // MARK: I1 — the anchor round-trips EXACTLY (sub-ms precision is not truncated)

    @Test("a sub-millisecond anchor round-trips exactly, so it cannot self-expire (I1)")
    internal func anchorRoundTripsExactly() async throws {
        // A realistic chat.db timestamp has sub-millisecond precision; a `.datetime`
        // column would truncate it and the SAME message would read as strictly newer.
        let subMs = Date(timeIntervalSinceReferenceDate: 700_123.456_789_012)
        let store = try StowerTriageStore.inMemory()
        try await store.dismiss(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: subMs,
            dismissedAt: subMs
        )
        let read = try await store.dismissedMessages()[Self.handle]?.anchorTimestamp
        #expect(read == subMs)
        // The exact value is not strictly newer than itself → would stay hidden.
        #expect((read.map { subMs <= $0 }) == true)
    }

    // MARK: I2 — retiring a dismissal MOVES it (state loses a row, history gains one)

    @Test("retiring a dismissal moves it into history atomically (I2)")
    internal func retireMovesToHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerTriageStore.fileName)

        let store = try StowerTriageStore.open(at: url)
        try await store.dismiss(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: Self.anchor,
            dismissedAt: Self.anchor
        )
        try await store.retireDismissal(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: Self.anchor,
            retiredAt: Self.newer
        )

        #expect(try await store.dismissedMessages().isEmpty)
        #expect(try count("dismissed_message", at: url) == 0)
        #expect(try count("dismissal_history", at: url) == 1)
    }

    // MARK: I5 — a stale/concurrent retire affects zero rows (idempotent + guarded)

    @Test("a second retire of the same dismissal is a clean no-op (I5)")
    internal func retireIsIdempotent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerTriageStore.fileName)

        let store = try StowerTriageStore.open(at: url)
        try await store.dismiss(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: Self.anchor,
            dismissedAt: Self.anchor
        )
        try await store.retireDismissal(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: Self.anchor,
            retiredAt: Self.newer
        )
        // A superseded second pass retires the same anchor: matches zero rows.
        try await store.retireDismissal(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: Self.anchor,
            retiredAt: Self.newer
        )

        #expect(try count("dismissal_history", at: url) == 1)
        #expect(try count("dismissed_message", at: url) == 0)
    }

    @Test("retiring a stale anchor (a newer dismiss replaced it) moves nothing (I5)")
    internal func retireGuardsOnAnchor() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerTriageStore.fileName)

        let store = try StowerTriageStore.open(at: url)
        try await store.dismiss(
            handleKey: Self.handle,
            messageGUID: "g2",
            anchorTimestamp: Self.newer,
            dismissedAt: Self.newer
        )
        // A retire racing the OLD anchor must not move the new active dismissal.
        try await store.retireDismissal(
            handleKey: Self.handle,
            messageGUID: "g1",
            anchorTimestamp: Self.anchor,
            retiredAt: Self.newer
        )

        #expect(try count("dismissal_history", at: url) == 0)
        #expect(try await store.dismissedMessages()[Self.handle]?.messageGUID == "g2")
    }

    // MARK: I8 — every mute/unmute appends to history; muted_contact stays ≤1 per handle

    @Test("mute and unmute each append a history event; current state stays ≤1 row (I8)")
    internal func muteUnmuteAppendsHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerTriageStore.fileName)

        let store = try StowerTriageStore.open(at: url)
        try await store.mute(handleKey: Self.handle, mutedAt: Self.anchor)
        #expect(try await store.muted().map(\.handleKey) == [Self.handle])
        #expect(try count("muted_contact_history", at: url) == 1)

        try await store.unmute(handleKey: Self.handle, unmutedAt: Self.newer)
        #expect(try await store.muted().isEmpty)
        #expect(try count("muted_contact_history", at: url) == 2)

        try await store.mute(handleKey: Self.handle, mutedAt: Self.newer)
        #expect(try await store.muted().map(\.handleKey) == [Self.handle])
        #expect(try count("muted_contact_history", at: url) == 3)
        // Re-mute never duplicates the active row.
        #expect(try count("muted_contact", at: url) == 1)
    }

    // MARK: I10 — a reopen never wipes precious triage intent

    @Test("dismiss + mute survive release and reopen — no wipe on reopen (I10)")
    internal func reopenPreservesIntent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(StowerTriageStore.fileName)

        do {
            let store = try StowerTriageStore.open(at: url)
            try await store.dismiss(
                handleKey: Self.handle,
                messageGUID: "g1",
                anchorTimestamp: Self.anchor,
                dismissedAt: Self.anchor
            )
            try await store.mute(handleKey: Self.other, mutedAt: Self.anchor)
        }

        let reopened = try StowerTriageStore.open(at: url)
        #expect(try await reopened.dismissedMessages()[Self.handle]?.messageGUID == "g1")
        #expect(try await reopened.muted().map(\.handleKey) == [Self.other])
    }
}
