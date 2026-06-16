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
        guard case .available = StowerLanguageModelAvailability.current() else {
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

    @Test("an in-flight on-device respond aborts when its task is cancelled (A7)")
    internal func liveModelHonorsCooperativeCancellation() async throws {
        guard #available(macOS 26, *) else {
            Issue.record("FoundationModels needs macOS 26 — does not skip; run on the dev machine.")
            return
        }
        guard case .available = StowerLanguageModelAvailability.current() else {
            Issue.record("FoundationModels unavailable — does not skip; enable Apple Intelligence.")
            return
        }

        // The whole per-record-timeout design rests on A7: a cancelled in-flight
        // `respond` must actually abort. Start the judge, let it pass its
        // pre-`respond` `try Task.checkCancellation()` guard and enter the on-device
        // call, THEN cancel — a pre-cancelled task would abort at that guard and
        // never exercise FoundationModels' own cancellation, falsely "proving" A7.
        let judge = StowerFoundationModelReplyJudge()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await judge.judge(messageText: "are we still on for saturday?", context: [])
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        // A7 holds iff the cancelled call THROWS instead of running to completion
        // and returning a verdict — and aborts well under an uncancelled run
        // (~2.4s on the dev machine), not after it.
        await #expect(throws: (any Error).self) {
            _ = try await task.value
        }
        #expect(clock.now - start < .seconds(2))
    }
}
