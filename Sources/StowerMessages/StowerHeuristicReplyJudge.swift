import Foundation

/// The deterministic availability fallback: `?` plus ask-cue detection.
///
/// Used on Macs that can't run FoundationModels, and inline on the load path
/// when no cached language-model verdict exists. It judges by INTENT, not just
/// punctuation — "wondering if you're free Saturday" expects a reply with no
/// `?` — but still misses novel phrasings, which is why the language model is
/// the primary path on capable Macs. Confidence is graded so `ghostGateThreshold`
/// is a live knob even here. Internal: the judge seam is module-private.
internal struct StowerHeuristicReplyJudge: StowerReplyExpectationJudge {
    /// Lowercased ask-cues that read as expecting a reply without a `?`.
    private static let cues = [
        "let me know", "lmk", "can you", "could you", "wondering if",
        "are you", "you free", "we should", "wanna"
    ]

    /// The template fingerprinted into `judgeVersion`; bump implies a re-judge.
    private static let promptTemplate = "heuristic:cues=\(cues.joined(separator: ","))|qmark"

    /// The derived cache-key fingerprint of this judge's cue set (M12).
    internal let judgeVersion: String

    /// Creates a heuristic judge.
    internal init() {
        judgeVersion = stowerShortHash(Self.promptTemplate + "|model=heuristic")
    }

    /// Judges `messageText` by `?` plus ask-cues; a nil text never expects one.
    internal func judge(messageText: String?, context: [String]) async -> StowerReplyExpectation {
        guard let text = messageText?.lowercased() else {
            return verdict(expectsReply: false, confidence: 0)
        }
        let hasQuestion = text.contains("?")
        let hasCue = Self.cues.contains { text.contains($0) }
        let confidence = Self.confidence(hasCue: hasCue, hasQuestion: hasQuestion)
        return verdict(expectsReply: confidence > 0, confidence: confidence)
    }

    /// Grades confidence: cue+`?` strongest, then cue-only, then bare `?`.
    private static func confidence(hasCue: Bool, hasQuestion: Bool) -> Double {
        switch (hasCue, hasQuestion) {
        case (true, true): return 1.0
        case (true, false): return 0.6
        case (false, true): return 0.4
        case (false, false): return 0.0
        }
    }

    private func verdict(expectsReply: Bool, confidence: Double) -> StowerReplyExpectation {
        StowerReplyExpectation(
            expectsReply: expectsReply,
            replyExpectationConfidence: confidence,
            verdictSource: .heuristic,
            reason: nil
        )
    }
}
