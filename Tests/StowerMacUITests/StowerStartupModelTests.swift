import Foundation
import Testing

@testable import StowerMacUI

/// The startup ordering, routing, and re-entrancy invariants.
///
/// All driven by the Tests-only `StowerFakeStartupProvider` (no engine, no real
/// model). Injects a no-op sleep so the minimum-display delay adds no wall-clock
/// wait.
@Suite @MainActor internal struct StowerStartupModelTests {
    /// Builds a model over `provider` with the minimum-display delay disabled.
    ///
    /// The license gate defaults to "licensed" so the pre-license routing
    /// tests reach the board flow unchanged; the licensing tests pass their own.
    private func makeModel(
        provider: StowerFakeStartupProvider,
        licenseGate: any StowerLicenseGating = StowerFakeLicenseGate(states: [.licensed]),
        config: StowerStartupDebtConfig = .appDefault,
        onCommit: (@MainActor @Sendable (StowerStartupState) -> Void)? = nil
    ) -> StowerStartupModel {
        StowerStartupModel(
            provider: provider,
            licenseGate: licenseGate,
            config: config,
            sleep: { _ in },
            onCommit: onCommit
        )
    }

    @Test("availability is checked before the board load on the happy path")
    internal func availabilityPrecedesLoad() async {
        let provider = StowerFakeStartupProvider()
        let model = makeModel(provider: provider)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
        #expect(await provider.recordedCalls == [.availability, .load])
    }

    @Test(
        "a preflight-unavailable reason renders the model screen and never loads",
        arguments: [
            StowerStartupModelUnavailableReason.deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unknown
        ]
    )
    internal func preflightUnavailableRoutesWithoutLoad(
        reason: StowerStartupModelUnavailableReason
    ) async {
        let provider = StowerFakeStartupProvider(availability: .unavailable(reason))
        let model = makeModel(provider: provider)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .modelUnavailable(reason))
        #expect(await provider.loadCallCount == 0)
    }

    @Test(
        "an in-load model-unavailable wins over a messages-access/source error",
        arguments: [
            StowerStartupModelUnavailableReason.deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unknown
        ]
    )
    internal func inLoadModelUnavailableWins(
        reason: StowerStartupModelUnavailableReason
    ) async {
        let provider = StowerFakeStartupProvider(
            availability: .available,
            loadBehaviors: [.failure(.modelUnavailable(reason))]
        )
        let model = makeModel(provider: provider)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .modelUnavailable(reason))
    }

    @Test("a load messages-access failure routes to needsMessagesAccess")
    internal func messagesAccessFailureRoutesToOnboarding() async {
        let detail = "no Messages folder selected yet"
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.failure(.messagesAccessMissing(detail: detail))]
        )
        let model = makeModel(provider: provider)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsMessagesAccess)
    }

    @Test("invalid config routes to .failed; preflight ran once, no extra work")
    internal func invalidConfigRoutesToFailed() async {
        let provider = StowerFakeStartupProvider(windowDays: 180)
        let model = makeModel(
            provider: provider,
            config: StowerStartupDebtConfig(unansweredForDays: 181)
        )
        model.start()
        await model.activeRun?.value
        #expect(model.state == .failed(.invalidConfig))
        #expect(await provider.availabilityCallCount == 1)
        #expect(await provider.loadCallCount == 1)
    }

    @Test(
        "non-messages-access failures route to .failed, never to the access screen",
        arguments: [
            StowerStartupFailure.sourceMissing,
            .unreadable,
            .invalidData
        ]
    )
    internal func nonMessagesAccessFailuresRouteToFailed(failure: StowerStartupFailure) async {
        let provider = StowerFakeStartupProvider(loadBehaviors: [.failure(failure)])
        let model = makeModel(provider: provider)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .failed(failure))
    }

    @Test(
        "Check Again reruns the flow; a second messages-access result escalates to still-missing"
    )
    internal func checkAgainRerunsAndEscalates() async {
        let detail = "no Messages folder selected yet"
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.failure(.messagesAccessMissing(detail: detail))]
        )
        let model = makeModel(provider: provider)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsMessagesAccess)

        model.checkAgain()
        await model.activeRun?.value
        #expect(model.state == .needsMessagesAccessStillMissing(detail: detail))
        #expect(await provider.loadCallCount == 2)
    }

    @Test("an overlapping Check Again cancels the in-flight run without routing to .failed")
    internal func overlappingCheckAgainDiscardsStaleRun() async {
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.blockUntilCancelled, .success]
        )
        let model = makeModel(provider: provider)
        model.start()
        // Let the first run reach (and block inside) the load before superseding it.
        while await provider.loadCallCount < 1 {
            await Task.yield()
        }
        model.checkAgain()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
        #expect(await provider.loadCallCount == 2)
    }

    @Test("cancel() stops the in-flight run without routing to .failed")
    internal func cancelStopsInFlightRun() async {
        let provider = StowerFakeStartupProvider(loadBehaviors: [.blockUntilCancelled])
        let model = makeModel(provider: provider)
        model.start()
        while await provider.loadCallCount < 1 {
            await Task.yield()
        }
        let run = model.activeRun
        model.cancel()
        await run?.value
        // The cancelled run never routes to a failure screen; it stays at the
        // checking state it had reached, and no new run is started.
        #expect(model.state == .checkingMessages)
        #expect(model.activeRun == nil)
    }
}
