import Foundation
import Testing

@testable import StowerMessages

/// The only real-model coverage.
///
/// The model's output is non-deterministic, so this asserts the contract (a
/// typed `.languageModel` verdict, a clear question judged as expecting a
/// reply), not an exact confidence.
///
/// It FAILS LOUDLY when FoundationModels is unavailable — it never skip-passes
/// on an incapable machine — per the no-skip rule. Run it on the macOS 26 +
/// Apple Intelligence dev machine, where it executes for real.
@Suite("StowerFoundationModelReplyJudge (integration)")
internal struct StowerFMReplyJudgeIntegrationTests {
    @Test("the on-device model judges a clear question as expecting a reply")
    internal func liveModelJudgesAClearQuestion() async throws {
        guard #available(macOS 26, *) else {
            Issue.record("FoundationModels needs macOS 26 — does not skip; run on the dev machine.")
            return
        }
        guard StowerLanguageModelAvailability.isAvailable() else {
            Issue.record("FoundationModels unavailable — does not skip; enable Apple Intelligence.")
            return
        }

        let judge = StowerFoundationModelReplyJudge()
        let verdict = try await judge.judge(
            messageText: "are we still on for saturday?",
            context: []
        )

        #expect(verdict.verdictSource == .languageModel)
        #expect(verdict.expectsReply)
        #expect(verdict.replyExpectationConfidence >= 0)
        #expect(verdict.replyExpectationConfidence <= 1)
    }
}
