import Foundation

@testable import StowerMacUI

/// A triage store double whose WRITES throw — for the view-model failure paths (no
/// success bar on a failed dismiss; degrade-not-crash on a failed mute).
///
/// Distinct from `StowerLiveBoardDataSourceTests`'s read-throwing double (whose writes
/// are no-ops): here the writes are what fail.
internal struct StowerFailingWriteTriageStore: StowerTriageStoring {
    /// The error every write throws.
    internal struct Failure: Error {}

    internal func dismissedMessages() async throws -> [String: StowerDismissedAnchor] {
        [:]
    }

    internal func muted() async throws -> Set<String> {
        []
    }

    internal func dismiss(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws {
        throw Failure()
    }

    internal func undismiss(handleKey: String) async throws {
        throw Failure()
    }

    internal func retireDismissal(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws {
        throw Failure()
    }

    internal func mute(handleKey: String, at: Date) async throws {
        throw Failure()
    }

    internal func unmute(handleKey: String, at: Date) async throws {
        throw Failure()
    }
}
