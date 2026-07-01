import Foundation
import Testing

@testable import StowerMacUI

/// Tests the license/trial funnel (PA3) analytics emission — `trial_started`
/// per-install seeding, `paywall_reached` on forced paywall arrivals (startup
/// routing and the on-board expiry re-check), and `activated` on a successful
/// activation.
///
/// Split from `StowerAnalyticsFunnelTests` to keep each suite within the
/// type-body length budget. Same `StowerFakeStartupProvider` +
/// `StowerFakeLicenseGate` + `StowerInMemoryAnalyticsReporter` doubles — no
/// engine, no network, and a no-op minimum-display sleep.
@Suite @MainActor internal struct StowerAnalyticsFunnelLicenseTests {

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

    @Test("on-board expiry re-check emits exactly one paywall_reached and no new hardware_checked")
    internal func expiryRecheckEmitsPaywallReachedOnce() async throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StowerFakeStartupProvider()
        let licenseGate = StowerFakeLicenseGate(states: [.trial(expiry: expiry), .expired])
        let spy = StowerInMemoryAnalyticsReporter()
        let model = makeModel(provider: provider, licenseGate: licenseGate, reporter: spy)
        model.start()
        let run = try #require(model.activeRun)
        await run.value
        #expect(model.state == .connectedPreparingBoard)
        let hardwareCheckedBefore = spy.recorded()
            .filter { $0.signalName == "hardware_checked" }.count

        // The trial expired while the board was up; the foreground/scheduled
        // re-check routes to the paywall — a genuine forced arrival.
        await model.refreshLicenseIfOnBoard()
        #expect(model.state == .needsLicense(nil))
        let paywallCount = spy.recorded().filter { $0.signalName == "paywall_reached" }.count
        #expect(
            paywallCount == 1,
            "the expiry re-check is a real paywall arrival: exactly one paywall_reached"
        )
        let hardwareCheckedAfter = spy.recorded()
            .filter { $0.signalName == "hardware_checked" }.count
        #expect(
            hardwareCheckedAfter == hardwareCheckedBefore,
            "hardware_checked stays latched by hardwareCheckedThisRun on the re-check path"
        )

        // Off the board, further re-checks are no-ops — no double-count.
        await model.refreshLicenseIfOnBoard()
        let paywallCountAfterSecond = spy.recorded()
            .filter { $0.signalName == "paywall_reached" }.count
        #expect(paywallCountAfterSecond == 1)
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
}
