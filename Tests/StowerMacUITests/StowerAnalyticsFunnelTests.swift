import Foundation
import Testing

@testable import StowerMacUI

/// Tests the startup funnel analytics emission: per-launch / per-occurrence
/// semantics, the `wasAwaitingMessagesAccess` latch, and a Check-Again sequence (Eng F1/F2).
///
/// Uses `StowerFakeStartupProvider` and `StowerInMemoryAnalyticsReporter` so no
/// engine or real UserDefaults is involved.
@Suite @MainActor internal struct StowerAnalyticsFunnelTests {

    private func makeModel(
        provider: StowerFakeStartupProvider,
        licenseGate: any StowerLicenseGating = StowerFakeLicenseGate(states: [.licensed]),
        reporter: StowerInMemoryAnalyticsReporter
    ) -> StowerStartupModel {
        StowerStartupModel(
            provider: provider,
            licenseGate: licenseGate,
            sleep: { _ in },
            reporter: reporter
        )
    }

    // MARK: — Happy path

    @Test("happy path emits hardware_checked(supported:true) then board_reached")
    internal func happyPathFunnelEvents() async throws {
        let provider = StowerFakeStartupProvider()
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        let events = spy.recorded()
        let names = events.map(\.signalName)
        #expect(names.contains("hardware_checked"))
        #expect(names.contains("board_reached"))

        let hwEvent = events.first { $0.signalName == "hardware_checked" }
        #expect(hwEvent?.parameters["supported"] == "true")
    }

    @Test("board_reached fires once per launch even after Check Again")
    internal func boardReachedOncePerLaunch() async throws {
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.success, .success]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        let run1 = try #require(model.activeRun)
        await run1.value
        model.checkAgain()
        let run2 = try #require(model.activeRun)
        await run2.value

        let boardReachedCount = spy.recorded().filter { $0.signalName == "board_reached" }.count
        #expect(boardReachedCount == 1, "board_reached must fire at most once per launch")
    }

    // MARK: — Messages-access latch

    @Test("Messages-access latch: resolved fires after an awaiting-access run reaches board")
    internal func messagesAccessLatchResolution() async throws {
        // First run: messages access missing.
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.messagesAccessMissing(detail: "/var/db")),
                .success
            ]
        )
        let licenseGate = StowerFakeLicenseGate(states: [.licensed, .licensed])
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run1 = try #require(model.activeRun)
        await run1.value

        let namesAfterMissing = spy.recorded().map(\.signalName)
        #expect(namesAfterMissing.contains("messages_access_requested"))
        #expect(namesAfterMissing.filter { $0 == "messages_access_resolved" }.isEmpty)

        // Second run: messages access now granted (provider succeeds).
        model.checkAgain()
        let run2 = try #require(model.activeRun)
        await run2.value

        let namesAfterGrant = spy.recorded().map(\.signalName)
        #expect(namesAfterGrant.contains("messages_access_resolved"))
        let resolvedEvent = spy.recorded().first { $0.signalName == "messages_access_resolved" }
        #expect(resolvedEvent?.parameters["granted"] == "true")
    }

    @Test("messages_access_requested does not double-fire under Check Again while still missing")
    internal func messagesAccessRequestedNotDoubledUnderCheckAgain() async throws {
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.messagesAccessMissing(detail: "/var/db")),
                .failure(.messagesAccessMissing(detail: "/var/db"))
            ]
        )
        let licenseGate = StowerFakeLicenseGate(states: [.licensed, .licensed])
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run1 = try #require(model.activeRun)
        await run1.value
        // Second run: still missing (still in the same awaiting-access arc).
        model.checkAgain()
        let run2 = try #require(model.activeRun)
        await run2.value

        let requestedCount = spy.recorded()
            .filter { $0.signalName == "messages_access_requested" }
            .count
        #expect(
            requestedCount == 1,
            "messages_access_requested must fire once per awaiting-access arc"
        )
    }

    @Test("checkingMessages without a board reach does not record access granted")
    internal func messagesAccessResolvedNotFiredOnPrematureCheckingMessages() async throws {
        // Both runs: license valid (so each commits .checkingMessages before the
        // load), but the board load fails with messages access missing — access was never
        // actually granted. The second run is the awaiting-access recheck that
        // reaches .checkingMessages with the latch set; granted:true must NOT be
        // recorded because the board (proof of access) is never reached.
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.messagesAccessMissing(detail: "/var/db")),
                .failure(.messagesAccessMissing(detail: "/var/db"))
            ]
        )
        let licenseGate = StowerFakeLicenseGate(states: [.licensed, .licensed])
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run1 = try #require(model.activeRun)
        await run1.value
        model.checkAgain()
        let run2 = try #require(model.activeRun)
        await run2.value

        let resolvedCount = spy.recorded()
            .filter { $0.signalName == "messages_access_resolved" }
            .count
        #expect(
            resolvedCount == 0,
            "granted must not be recorded when access was never proven (board never reached)"
        )
    }

    // The license/trial funnel (PA3) tests live in
    // `StowerAnalyticsFunnelLicenseTests` — split to keep each suite within
    // the type-body length budget.

    // MARK: — Board failure routing

    @Test("handleBoardFailure routing to needsMessagesAccess emits messages_access_requested")
    internal func boardFailureRoutesToMessagesAccessEmitsFunnelEvent() async throws {
        let provider = StowerFakeStartupProvider()
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        // Simulate a mid-session board failure: messages access revoked.
        model.handleBoardFailure(.messagesAccessMissing(detail: "/var/db"))

        let names = spy.recorded().map(\.signalName)
        #expect(
            names.contains("messages_access_requested"),
            "handleBoardFailure routing to needsMessagesAccess must emit messages_access_requested"
        )
    }

    @Test("handleBoardFailure routing to .failed routes through commit")
    internal func boardFailureRoutesToFailedEmitsViaCommit() async throws {
        let provider = StowerFakeStartupProvider()
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        // Simulate a mid-session board failure that routes to .failed.
        model.handleBoardFailure(.unexpected)

        // .unexpected routes to .failed, which does NOT emit paywall_reached;
        // verify the commit path is exercised (state changed correctly).
        #expect(model.state == .failed(.unexpected))
    }

    // MARK: — Hardware unavailable

    @Test("hardware_checked(supported:false) fires when model is unavailable")
    internal func hardwareUnavailable() async throws {
        let provider = StowerFakeStartupProvider(
            availability: .unavailable(.deviceNotEligible)
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        let hwEvent = spy.recorded().first { $0.signalName == "hardware_checked" }
        #expect(hwEvent?.parameters["supported"] == "false")
    }

    @Test("hardware_checked fires only once when loadDebtBoard throws modelUnavailable mid-run")
    internal func hardwareCheckedDoesNotDoubleFireWithinOneRun() async throws {
        // Preflight availability passes (so route() commits the optimistic,
        // funnel-silent .checkingMessages), but loadDebtBoard itself then throws
        // .modelUnavailable — a real path (e.g. Apple Intelligence toggled off
        // between the preflight and the load). Only the run's true terminal
        // outcome (supported:false) is recorded, exactly once.
        let provider = StowerFakeStartupProvider(
            availability: .available,
            loadBehaviors: [.failure(.modelUnavailable(.deviceNotEligible))]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        let hwEvents = spy.recorded().filter { $0.signalName == "hardware_checked" }
        #expect(hwEvents.count == 1, "one run must report hardware_checked exactly once")
        #expect(hwEvents.first?.parameters["supported"] == "false")
    }
}
