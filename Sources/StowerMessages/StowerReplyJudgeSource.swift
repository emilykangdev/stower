import Foundation

/// Which judge produced a reply-expectation verdict.
///
/// The string raw value doubles as the verdict cache's stored source token, so
/// renaming the case is a cache-schema change. Apple's on-device FoundationModels
/// judge (and a future MLX judge) reports `.languageModel`; a deterministic rule
/// the text model can't apply (a counterpart attachment) reports
/// `.nonTextContent`. Both are trusted. Internal: once the public row is collapsed
/// and `StowerReplyExpectation` is internal, nothing public references it; it stays
/// the cache token and the single home of the trust definition.
internal enum StowerReplyJudgeSource: String, Sendable, Equatable {
    /// An on-device language model (FoundationModels or a future MLX) produced it.
    case languageModel

    /// A deterministic non-model rule produced it — e.g. a counterpart attachment
    /// the text model can't read but which plainly invites a reply. Trusted
    /// because it is a fixed rule with no hallucination risk, not a guess.
    case nonTextContent

    /// The sources whose cached verdicts the board trusts.
    ///
    /// One definition, read and write, for every call site. A new judge — model
    /// or deterministic rule — earns trust by being added here.
    internal static let trustedSources: Set<StowerReplyJudgeSource> = [
        .languageModel, .nonTextContent
    ]

    /// Whether a verdict from this source is trusted to reach the board.
    internal var isTrustedVerdictSource: Bool {
        Self.trustedSources.contains(self)
    }
}
