import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerModelAvailability")
internal struct StowerModelAvailabilityTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("each unavailable reason carries a distinct, actionable error description")
    internal func reasonsHaveActionableMessages() {
        let reasons: [StowerModelUnavailableReason] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unknown
        ]
        let messages = reasons.map {
            StowerMessagesError.languageModelUnavailable($0).errorDescription ?? ""
        }
        // Every reason maps to a non-empty, distinct message so the app can route
        // and surface a fixable/transient/terminal state correctly.
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == reasons.count)
        // The fixable state names the user action; the terminal one names the cause.
        #expect(
            StowerMessagesError.languageModelUnavailable(.appleIntelligenceNotEnabled)
                .errorDescription?.contains("System Settings") == true
        )
        #expect(
            StowerMessagesError.languageModelUnavailable(.deviceNotEligible)
                .errorDescription?.contains("can't run Apple Intelligence") == true
        )
    }

    @Test("the provider reports each injected availability state verbatim")
    internal func providerReportsInjectedAvailability() async {
        let states: [StowerModelAvailability] = [
            .available,
            .unavailable(.deviceNotEligible),
            .unavailable(.appleIntelligenceNotEnabled),
            .unavailable(.modelNotReady),
            .unavailable(.unknown)
        ]
        for state in states {
            let provider = StowerDebtBoardProvider(
                readerFactory: { StowerStubFactsReader(records: []) },
                languageModelJudge: nil,
                cache: nil,
                modelAvailabilityResolver: { state }
            )
            #expect(await provider.modelAvailability() == state)
        }
    }

    @Test("availability passes but a nil judge throws .modelNotReady, never a silent empty board")
    internal func availableNilJudgeThrowsNotEmptyBoard() async {
        // Availability resolves .available (the default) but the judge resolves to nil
        // — a model evicted between the two resolves, or a construction fault.
        // loadDebtBoard must fail loud, never return an empty board the user would read
        // as "all caught up" when judging actually failed.
        let provider = StowerDebtBoardProvider(
            readerFactory: { StowerStubFactsReader(records: []) },
            languageModelJudge: nil,
            cache: nil
        )
        do {
            _ = try await provider.loadDebtBoard(
                config: StowerDebtConfig(unansweredForDays: 7),
                now: now
            )
            Issue.record("expected loadDebtBoard to throw, not return an empty board")
        } catch let error as StowerMessagesError {
            guard case .languageModelUnavailable(.modelNotReady) = error else {
                Issue.record("expected languageModelUnavailable(.modelNotReady), got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
