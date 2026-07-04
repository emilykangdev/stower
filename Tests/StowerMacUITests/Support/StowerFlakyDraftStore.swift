import Foundation

@testable import StowerMacUI

/// A draft store whose reads can be made to fail (to exercise the merge path's
/// failure handling — a failed read must not wipe local drafts) and whose next N
/// writes can be made to throw (to exercise the write-through retry, including
/// `markSent`/`unmarkSent`, I12).
///
/// Shared by `StowerBoardViewModelDraftsTests` and
/// `StowerBoardViewModelDraftResolveTests`.
internal actor StowerFlakyDraftStore: StowerDraftStoring {
    private var entries: [String: StowerDraftEntry]
    private var failReads = false
    private var failNextWrites = 0

    internal init(entries: [String: StowerDraftEntry]) {
        self.entries = entries
    }

    internal func setFailReads(_ failReads: Bool) {
        self.failReads = failReads
    }

    /// Makes the next `count` write attempts (upsert/delete/markSent/unmarkSent)
    /// throw before succeeding.
    internal func setFailNextWrites(_ count: Int) {
        failNextWrites = count
    }

    internal func all() throws -> [String: StowerDraftEntry] {
        guard !failReads else { throw StowerFlakyDraftStoreError.readFailed }
        return entries
    }

    internal func upsert(key: String, body: String) throws {
        try failWriteIfArmed()
        entries[key] = StowerDraftEntry(body: body, updatedAt: Date())
    }

    internal func delete(key: String) throws {
        try failWriteIfArmed()
        entries[key] = nil
    }

    internal func markSent(key: String) throws {
        try failWriteIfArmed()
        guard let entry = entries[key] else { return }
        entries[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: Date()
        )
    }

    internal func unmarkSent(key: String) throws {
        try failWriteIfArmed()
        guard let entry = entries[key] else { return }
        entries[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: nil
        )
    }

    private func failWriteIfArmed() throws {
        guard failNextWrites > 0 else { return }
        failNextWrites -= 1
        throw StowerFlakyDraftStoreError.writeFailed
    }
}

internal enum StowerFlakyDraftStoreError: Error {
    case readFailed
    case writeFailed
}
