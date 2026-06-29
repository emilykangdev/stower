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
        licenseGate: any StowerLicenseGating = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.valid)]
        ),
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
    internal func happyPathFunnelEvents() async {
        let provider = StowerFakeStartupProvider()
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        await model.activeRun?.value

        let events = spy.recorded()
        let names = events.map(\.signalName)
        #expect(names.contains("hardware_checked"))
        #expect(names.contains("board_reached"))

        let hwEvent = events.first { $0.signalName == "hardware_checked" }
        #expect(hwEvent?.parameters["supported"] == "true")
    }

    @Test("board_reached fires once per launch even after Check Again")
    internal func boardReachedOncePerLaunch() async {
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.success, .success]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        await model.activeRun?.value
        model.checkAgain()
        await model.activeRun?.value

        let boardReachedCount = spy.recorded().filter { $0.signalName == "board_reached" }.count
        #expect(boardReachedCount == 1, "board_reached must fire at most once per launch")
    }

    // MARK: — FDA latch

    @Test("FDA latch: fda_permission_resolved fires after wasAwaitingFDA run reaches board")
    internal func fdaLatchResolution() async {
        // First run: FDA missing.
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.fullDiskAccessMissing(path: "/var/db")),
                .success
            ]
        )
        let licenseGate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.valid), .status(.valid)]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        await model.activeRun?.value

        let namesAfterFDA = spy.recorded().map(\.signalName)
        #expect(namesAfterFDA.contains("fda_permission_requested"))
        #expect(namesAfterFDA.filter { $0 == "fda_permission_resolved" }.isEmpty)

        // Second run: FDA now granted (provider succeeds).
        model.checkAgain()
        await model.activeRun?.value

        let namesAfterGrant = spy.recorded().map(\.signalName)
        #expect(namesAfterGrant.contains("fda_permission_resolved"))
        let resolvedEvent = spy.recorded().first { $0.signalName == "fda_permission_resolved" }
        #expect(resolvedEvent?.parameters["granted"] == "true")
    }

    @Test("fda_permission_requested does not double-fire under Check Again while still missing")
    internal func fdaRequestedNotDoubledUnderCheckAgain() async {
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [
                .failure(.fullDiskAccessMissing(path: "/var/db")),
                .failure(.fullDiskAccessMissing(path: "/var/db"))
            ]
        )
        let licenseGate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.valid), .status(.valid)]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        await model.activeRun?.value
        // Second run: still missing (still in the same awaiting-FDA arc).
        model.checkAgain()
        await model.activeRun?.value

        let requestedCount = spy.recorded()
            .filter { $0.signalName == "fda_permission_requested" }
            .count
        #expect(
            requestedCount == 1,
            "fda_permission_requested must fire once per awaiting-FDA arc"
        )
    }

    @Test("checkingMessages without a board reach does not record fda granted")
    internal func fdaResolvedNotFiredOnPrematureCheckingMessages() async {
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
        let licenseGate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.valid), .status(.valid)]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        await model.activeRun?.value
        model.checkAgain()
        await model.activeRun?.value

        let resolvedCount = spy.recorded()
            .filter { $0.signalName == "fda_permission_resolved" }
            .count
        #expect(
            resolvedCount == 0,
            "granted must not be recorded when access was never proven (board never reached)"
        )
    }

    // MARK: — License gate

    @Test("license_gate_reached fires when startup commits needsLicense")
    internal func licenseGateReachedFires() async {
        let provider = StowerFakeStartupProvider()
        let licenseGate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.trialExpired(licenseID: "test-id"))]
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        await model.activeRun?.value

        let names = spy.recorded().map(\.signalName)
        #expect(names.contains("license_gate_reached"))
        let gateEvent = spy.recorded().first { $0.signalName == "license_gate_reached" }
        #expect(gateEvent?.parameters["context"] == "trial_expired")
    }

    // MARK: — Hardware unavailable

    @Test("hardware_checked(supported:false) fires when model is unavailable")
    internal func hardwareUnavailable() async {
        let provider = StowerFakeStartupProvider(
            availability: .unavailable(.deviceNotEligible)
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, reporter: spy)
        model.start()
        await model.activeRun?.value

        let hwEvent = spy.recorded().first { $0.signalName == "hardware_checked" }
        #expect(hwEvent?.parameters["supported"] == "false")
    }
}
