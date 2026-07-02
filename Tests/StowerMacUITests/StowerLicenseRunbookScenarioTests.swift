import Foundation
import Testing

@testable import StowerMacUI

/// End-to-end licensing scenarios from the manual QA runbook, pinned as
/// deterministic tests so they need no `UserDefaults` mutation of the real
/// app domain, no Xcode scheme edits, and no wall-clock waiting.
///
/// S1/S2 (trial + F3 banner) live with the gate/banner unit suites; this file
/// covers the scenarios that span the real clock → gate → model → funnel:
/// S3 (expiry routes to the paywall and fires `paywall_reached`) and S4 (a
/// rejected key re-renders the paywall error without counting a new arrival).
/// Same `StowerFakeStartupProvider` + `StowerInMemoryAnalyticsReporter` doubles
/// as the other model suites — no engine, no network, a no-op display sleep.
@Suite @MainActor internal struct StowerLicenseRunbookScenarioTests {
    private let firstLaunch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Makes an isolated defaults suite for one test, pre-cleared.
    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// S3 end-to-end: a real trial clock seeded at first launch and read eight
    /// days later (past the 7-day window) drives the real gate + startup model
    /// to the paywall and emits `paywall_reached` — the programmatic equivalent
    /// of backdating `com.stower.trial.firstLaunch` to eight days ago.
    @Test("S3: an expired real trial routes to the paywall and fires paywall_reached")
    internal func expiredTrialRoutesToPaywallAndFiresPaywallReached() async throws {
        let suite = "stower.runbook.s3"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StowerTrialClock(defaults: defaults)
        _ = clock.state(now: firstLaunch)  // seed the first-launch date
        let eightDaysLater = firstLaunch.addingTimeInterval(8 * 24 * 60 * 60)
        let gate = StowerLemonSqueezyLicenseGate(
            client: StowerLemonSqueezyClient(expectedStoreID: 1, expectedProductID: 2),
            store: StowerLicenseStore(defaults: defaults),
            trialClock: clock
        )
        let spy = StowerInMemoryAnalyticsReporter()
        let model = StowerStartupModel(
            provider: StowerFakeStartupProvider(),
            licenseGate: gate,
            clock: { eightDaysLater },
            sleep: { _ in },
            reporter: spy
        )

        model.start()
        let run = try #require(model.activeRun)
        await run.value

        #expect(model.state == .needsLicense(nil))
        #expect(spy.recorded().map(\.signalName).contains("paywall_reached"))
    }

    /// S4: a rejected key re-renders the paywall with its error, but that is an
    /// error re-render of an already-counted visit — it must NOT emit a second
    /// `paywall_reached` (which would inflate the funnel's paywall count).
    @Test("S4: an invalid activation does not re-fire paywall_reached")
    internal func invalidActivationDoesNotRefirePaywallReached() async throws {
        let gate = StowerFakeLicenseGate(states: [.expired], activationResult: .invalid)
        let spy = StowerInMemoryAnalyticsReporter()
        let model = StowerStartupModel(
            provider: StowerFakeStartupProvider(),
            licenseGate: gate,
            sleep: { _ in },
            reporter: spy
        )
        model.start()
        let run = try #require(model.activeRun)
        await run.value
        let paywallBefore = spy.recorded().filter { $0.signalName == "paywall_reached" }.count
        #expect(paywallBefore == 1)

        let activated = await model.activate(key: "WRONG-KEY")

        #expect(!activated)
        #expect(model.state == .needsLicense(.invalid))
        let paywallAfter = spy.recorded().filter { $0.signalName == "paywall_reached" }.count
        #expect(paywallAfter == 1, "a rejected key re-renders the error, it is not a new arrival")
    }
}
