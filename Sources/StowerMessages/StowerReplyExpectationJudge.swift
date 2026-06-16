import CryptoKit
import Foundation

/// The swap seam for reply-expectation judgment.
///
/// Apple's FoundationModels judge conforms today; a future MLX judge is a drop-in
/// here with no change to the policies, the facade, or the app. A conformer judges
/// one message's text (`context` is reserved for future thread context and is
/// empty in v1) and reports its cache-key version for an app-owned model identity,
/// derived from the prompt + that identity so an edited prompt or a bumped model
/// epoch can never serve stale verdicts.
///
/// Internal: the swap seam is consumed inside the module (a future MLX judge is
/// an in-module conformer). The app depends on `StowerDebtBoardProvider`, never
/// on a judge, so this stays off the public surface.
internal protocol StowerReplyExpectationJudge: Sendable {
    /// Judges whether the recipient of `messageText` should respond.
    ///
    /// - Parameters:
    ///   - messageText: The message body, or `nil` for a non-text act (which
    ///     never expects a reply).
    ///   - context: Reserved for surrounding thread context; empty in v1.
    /// - Returns: The reply-expectation verdict.
    /// - Throws: A judge-specific error if the underlying model fails or the
    ///   task is cancelled.
    func judge(messageText: String?, context: [String]) async throws -> StowerReplyExpectation

    /// A stable fingerprint of this judge's prompt + the app-owned model identity
    /// (M12).
    ///
    /// Derived, never hand-bumped: changing the prompt template OR the supplied
    /// `modelIdentity` changes this, so an edited judge or a bumped model epoch
    /// misses the cache and re-judges instead of serving a stale verdict forever.
    /// The judge folds its own private prompt with `modelIdentity`; the caller
    /// never reads the judge's instructions.
    func judgeVersion(modelIdentity: String) -> String
}

/// A stable, process-independent short hash for cache keys and judge versions.
///
/// Uses SHA-256 rather than Swift's `Hasher`, which is seeded per process and
/// would invalidate the persistent verdict cache on every launch. Returns the
/// first 16 hex characters of the digest.
internal func stowerShortHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// Derives a judge's cache-key version from its prompt instructions and the
/// app-owned model identity (M12).
///
/// A pure, FM-free helper so it is unit-testable: changing either input changes
/// the version, so an edited prompt or a bumped model epoch can never serve a
/// stale verdict. A judge folds its own private instructions through this; the
/// caller supplies only `modelIdentity` and never reads the instructions.
internal func stowerJudgeVersion(instructions: String, modelIdentity: String) -> String {
    stowerShortHash(instructions + "|model=" + modelIdentity)
}
