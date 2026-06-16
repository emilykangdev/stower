import Foundation

/// Which judge produced a reply-expectation verdict.
///
/// The string raw value doubles as the verdict cache's stored source token, so
/// renaming the case is a cache-schema change. Apple's on-device FoundationModels
/// judge (and a future MLX judge) reports `.languageModel` — the only trusted
/// source. Internal: once the public row is collapsed and `StowerReplyExpectation`
/// is internal, nothing public references it; it stays the cache token and the
/// single home of the trust definition.
internal enum StowerReplyJudgeSource: String, Sendable, Equatable {
    /// An on-device language model (FoundationModels or a future MLX) produced it.
    case languageModel

    /// The sources whose cached verdicts the board trusts.
    ///
    /// One definition, read and write, for every call site. A new judge earns
    /// trust by being added here.
    internal static let trustedModelSources: Set<StowerReplyJudgeSource> = [.languageModel]

    /// Whether a verdict from this source is trusted to reach the board.
    internal var isTrustedModelVerdict: Bool {
        Self.trustedModelSources.contains(self)
    }
}
