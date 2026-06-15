import Foundation
import FoundationModels

/// The v1 real judge: Apple's on-device FoundationModels via guided generation.
///
/// `@available(macOS 26, *)` — the provider only constructs it after a runtime
/// `SystemLanguageModel.availability` check, and routes to the heuristic
/// otherwise. It judges by MEANING, not punctuation: "wondering if you're free
/// Saturday" expects a reply with no `?`. Guided generation yields a typed
/// `{ expectsReply, confidence }` directly — no text parsing, no malformed
/// output. The prompt carries real message text and is never logged (AGENTS.md).
/// Internal: the judge seam is module-private.
@available(macOS 26, *)
internal struct StowerFoundationModelReplyJudge: StowerReplyExpectationJudge {
    /// The model's role and decision rule.
    ///
    /// Fingerprinted into `judgeVersion` (M12), so editing it invalidates cached
    /// verdicts instead of serving them stale.
    private static let instructions = """
        You decide whether a single text message expects a reply from its \
        recipient. Judge by meaning, not punctuation: a question, a request, a \
        plan that needs confirmation, or anything awaiting a response expects a \
        reply, even without a question mark. A statement, an acknowledgment, a \
        reaction, or a sign-off does not. Report your confidence honestly.
        """

    /// A coarse identity for the on-device model, folded into `judgeVersion`.
    private static let modelIdentity = "foundationmodels-system-default"

    /// The derived cache-key fingerprint of the prompt + model identity (M12).
    internal let judgeVersion: String

    /// Creates a FoundationModels reply judge.
    internal init() {
        judgeVersion = stowerShortHash(Self.instructions + "|model=" + Self.modelIdentity)
    }

    /// Judges `messageText` with the on-device model via guided generation.
    internal func judge(
        messageText: String?,
        context: [String]
    ) async throws -> StowerReplyExpectation {
        guard let text = messageText,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.verdict(expectsReply: false, confidence: 0)
        }
        try Task.checkCancellation()
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: Self.prompt(for: text),
            generating: Verdict.self
        )
        let generated = response.content
        return Self.verdict(
            expectsReply: generated.expectsReply,
            confidence: min(max(generated.confidence, 0), 1)
        )
    }

    private static func prompt(for text: String) -> String {
        """
        Does this message expect a reply?

        \"\"\"
        \(text)
        \"\"\"
        """
    }

    private static func verdict(expectsReply: Bool, confidence: Double) -> StowerReplyExpectation {
        StowerReplyExpectation(
            expectsReply: expectsReply,
            replyExpectationConfidence: confidence,
            verdictSource: .languageModel,
            reason: nil
        )
    }

    /// The typed shape guided generation fills — no manual parsing.
    @Generable
    fileprivate struct Verdict {
        @Guide(description: "True if the message expects a reply or response from its recipient.")
        let expectsReply: Bool

        @Guide(description: "Confidence from 0.0 to 1.0 that the expectsReply decision is correct.")
        let confidence: Double
    }
}
