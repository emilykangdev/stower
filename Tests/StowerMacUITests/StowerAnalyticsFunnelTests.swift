import Foundation
import Testing

@testable import StowerMacUI

/// Tests the startup funnel analytics emission: per-launch / per-occurrence
/// semantics, the `wasAwaitingFDA` latch, and a Check-Again sequence (Eng F1/F2).
///
/// Uses `StowerFakeStartupProvider` and `StowerInMemoryAnalyticsReporter` so no
/// engine or real Keychain is involved.
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

    // MARK: — FDA latch

    @Test("FDA latch: fda_permission_resolved fires after wasAwaitingFDA run reaches board")
    internal func fdaLatchResolution() async throws {
        // First run: FDA missing.
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.fullDiskAccessMissing(path: "/var/db")),
                .success
            ]
        )
        let licenseGate = StowerFakeLicenseGate(states: [.licensed, .licensed])
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run1 = try #require(model.activeRun)
        await run1.value

        let namesAfterFDA = spy.recorded().map(\.signalName)
        #expect(namesAfterFDA.contains("fda_permission_requested"))
        #expect(namesAfterFDA.filter { $0 == "fda_permission_resolved" }.isEmpty)

        // Second run: FDA now granted (provider succeeds).
        model.checkAgain()
        let run2 = try #require(model.activeRun)
        await run2.value

        let namesAfterGrant = spy.recorded().map(\.signalName)
        #expect(namesAfterGrant.contains("fda_permission_resolved"))
        let resolvedEvent = spy.recorded().first { $0.signalName == "fda_permission_resolved" }
        #expect(resolvedEvent?.parameters["granted"] == "true")
    }

    @Test("fda_permission_requested does not double-fire under Check Again while still missing")
    internal func fdaRequestedNotDoubledUnderCheckAgain() async throws {
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.fullDiskAccessMissing(path: "/var/db")),
                .failure(.fullDiskAccessMissing(path: "/var/db"))
            ]
        )
        let licenseGate = StowerFakeLicenseGate(states: [.licensed, .licensed])
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run1 = try #require(model.activeRun)
        await run1.value
        // Second run: still missing (still in the same awaiting-FDA arc).
        model.checkAgain()
        let run2 = try #require(model.activeRun)
        await run2.value

        let requestedCount = spy.recorded()
            .filter { $0.signalName == "fda_permission_requested" }
            .count
        #expect(
            requestedCount == 1,
            "fda_permission_requested must fire once per awaiting-FDA arc"
        )
    }

    @Test("checkingMessages without a board reach does not record fda granted")
    internal func fdaResolvedNotFiredOnPrematureCheckingMessages() async throws {
        // Both runs: license valid (so each commits .checkingMessages before the
        // load), but the board load fails with FDA missing — access was never
        // actually granted. The second run is the awaiting-FDA recheck that
        // reaches .checkingMessages with the latch set; granted:true must NOT be
        // recorded because the board (proof of access) is never reached.
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.fullDiskAccessMissing(path: "/var/db")),
                .failure(.fullDiskAccessMissing(path: "/var/db"))
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
            .filter { $0.signalName == "fda_permission_resolved" }
            .count
        #expect(
            resolvedCount == 0,
            "granted must not be recorded when access was never proven (board never reached)"
        )
    }

    // MARK: — License / trial funnel (PA3)

    @Test("paywall_reached fires when startup commits needsLicense")
    internal func paywallReachedFires() async throws {
        let provider = StowerFakeStartupProvider()
        let licenseGate = StowerFakeLicenseGate(states: [.expired])
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        let names = spy.recorded().map(\.signalName)
        #expect(names.contains("paywall_reached"))
    }

    @Test("trial_started fires once per launch when an active trial is observed")
    internal func trialStartedFiresOncePerLaunch() async throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StowerFakeStartupProvider(loadBehaviors: [.success, .success])
        let licenseGate = StowerFakeLicenseGate(
            states: [.trial(expiry: expiry), .trial(expiry: expiry)]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run1 = try #require(model.activeRun)
        await run1.value
        model.checkAgain()
        let run2 = try #require(model.activeRun)
        await run2.value

        let trialStartedCount = spy.recorded().filter { $0.signalName == "trial_started" }.count
        #expect(trialStartedCount == 1, "trial_started must fire at most once per launch")
    }

    @Test("trial_started does NOT fire on a relaunch that merely observes an already-seeded trial")
    internal func trialStartedDoesNotFireOnRelaunch() async throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StowerFakeStartupProvider()
        // A fresh model instance simulates a relaunch: the trial clock was
        // already seeded on a prior launch (isFirstTrialObservation: false),
        // even though this launch's license read still observes .trial.
        let licenseGate = StowerFakeLicenseGate(
            states: [.trial(expiry: expiry)],
            firstTrialObservationResults: [false]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        let trialStartedCount = spy.recorded().filter { $0.signalName == "trial_started" }.count
        #expect(trialStartedCount == 0, "trial_started must not fire on a relaunch")
    }

    @Test("activated fires on a successful activation")
    internal func activatedFiresOnSuccess() async throws {
        let provider = StowerFakeStartupProvider()
        let licenseGate = StowerFakeLicenseGate(
            states: [.expired, .licensed],
            activationResult: .activated(instanceID: "inst-1")
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        await model.activate(key: "KEY")
        await model.activeRun?.value

        let names = spy.recorded().map(\.signalName)
        #expect(names.contains("activated"))
    }

    // MARK: — Board failure routing

    @Test("handleBoardFailure routing to needsFullDiskAccess emits fda_permission_requested")
    internal func boardFailureRoutesToFDAEmitsFunnelEvent() async throws {
        let provider = StowerFakeStartupProvider()
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value

        // Simulate a mid-session board failure: full disk access revoked.
        model.handleBoardFailure(.fullDiskAccessMissing(path: "/var/db"))

        let names = spy.recorded().map(\.signalName)
        #expect(
            names.contains("fda_permission_requested"),
            "handleBoardFailure routing to needsFullDiskAccess must emit fda_permission_requested"
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
