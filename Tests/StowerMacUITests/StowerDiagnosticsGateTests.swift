import Foundation
import Testing

@testable import StowerMacUI

/// Tests the `StowerDiagnostics` umbrella facade: disabled consent → neither
/// backend starts; one consent switch governs both backends (A6/JC3).
@Suite(.serialized) @MainActor internal struct StowerDiagnosticsGateTests {

    @Test internal func disabledConsent_neitherBackendStarts() async {
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)

        var analyticsClientCalled = false

        // Drive StowerDiagnostics.initialize with a disabled consent — neither
        // backend should fire (A6/JC3: one gate governs both).
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in analyticsClientCalled = true },
                startCrashReporting: { _ in Issue.record("crash reporting must not start") },
                stopCrashReporting: {}
            )
        )
        // The crash SDK gate is verified separately in StowerCrashReportingTests via
        // the injectable startSDK seam. We verify the analytics side (the only
        // injectable seam on the facade) as the proxy for "nothing started".

        #expect(
            analyticsClientCalled == false,
            "analytics backend must not start when consent is off"
        )
        #expect(StowerDiagnostics.isEnabled() == false)
    }

    @Test internal func enabledConsent_analyticsBackendStarts() async {
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnosticsConsent(storage: storage).setEnabled(true)
        var analyticsClientCalled = false
        var crashStartCalled = false

        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in analyticsClientCalled = true },
                startCrashReporting: { _ in crashStartCalled = true },
                stopCrashReporting: {}
            )
        )

        #expect(crashStartCalled == true, "crash backend must start when consent is on")
        #expect(analyticsClientCalled == true, "analytics backend must start when consent is on")
        #expect(StowerDiagnostics.isEnabled() == true)
    }

    @Test("fresh launch trace is empty until explicit consent, then starts Sentry first (I4)")
    internal func freshLaunchTrace_startsNothingBeforeConsent() async {
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        var trace: [String] = []

        StowerDiagnostics.initialize(
            consent: consent,
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in trace.append("telemetry-start") },
                startCrashReporting: { _ in trace.append("sentry-start") },
                stopCrashReporting: { trace.append("sentry-stop") }
            )
        )
        StowerAnalytics.reportAppLaunched()

        #expect(
            trace.isEmpty,
            "fresh launch trace must be empty before explicit consent"
        )

        StowerDiagnostics.setEnabled(
            true,
            consent: consent,
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in trace.append("telemetry-start") },
                startCrashReporting: { startConsent in
                    if startConsent.isEnabled {
                        trace.append("sentry-start")
                    }
                },
                stopCrashReporting: { trace.append("sentry-stop") }
            )
        )

        #expect(trace == ["sentry-start", "telemetry-start"])
    }

    @Test internal func setEnabled_false_disablesDiagnostics() async {
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnosticsConsent(storage: storage).setEnabled(true)
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in },
                startCrashReporting: { _ in },
                stopCrashReporting: {}
            )
        )
        #expect(StowerDiagnostics.isEnabled() == true)

        StowerDiagnostics.setEnabled(
            false,
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in },
                startCrashReporting: { _ in },
                stopCrashReporting: {}
            )
        )

        #expect(StowerDiagnostics.isEnabled() == false)
    }

    @Test("Off choice on fresh install persists hasMadeExplicitChoice (I5)")
    internal func setEnabledFalse_freshInstall_persistsExplicitChoice() async {
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)

        // Fresh install — no prior setEnabled(true) call.
        StowerDiagnostics.setEnabled(
            false,
            consent: consent,
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in },
                startCrashReporting: { _ in },
                stopCrashReporting: {}
            )
        )

        let afterConsent = StowerDiagnosticsConsent(storage: storage)
        #expect(afterConsent.isEnabled == false, "Off choice must persist isEnabled = false")
        #expect(
            afterConsent.hasMadeExplicitChoice == true,
            "Off choice must persist hasExplicitChoice = true so the consent card does not reappear"
        )
    }

    @Test internal func reconcileLicenseConsent_propagates() async {
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnosticsConsent(storage: storage).setEnabled(true)
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in },
                startCrashReporting: { _ in },
                stopCrashReporting: {}
            )
        )
        #expect(StowerDiagnostics.isEnabled() == true)

        StowerDiagnostics.reconcileLicenseConsent(licenseOptOut: true)

        // "Off wins" — license opt-out must propagate to isEnabled.
        #expect(StowerDiagnostics.isEnabled() == false)
    }

    @Test internal func reconcileLicenseOptOut_stopsCrashReporting() async {
        // Verifies that reconcileLicenseConsent(licenseOptOut: true) invokes the
        // crash-reporting stop closure (the Sentry mid-session close path).
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnosticsConsent(storage: storage).setEnabled(true)
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in },
                startCrashReporting: { _ in },
                stopCrashReporting: {}
            )
        )

        var stopCalled = false
        StowerDiagnostics.reconcileLicenseConsent(
            licenseOptOut: true,
            stopCrashReporting: { stopCalled = true }
        )

        #expect(stopCalled == true, "crash reporting stop must be called on license opt-out")
    }

    @Test internal func reconcileLicenseOptIn_doesNotStopCrashReporting() async {
        // Verifies that reconcileLicenseConsent(licenseOptOut: false) does NOT
        // invoke the crash-reporting stop closure (opt-in / no change path).
        StowerAnalytics.resetForTesting()
        StowerDiagnostics.resetForTesting()
        defer {
            StowerAnalytics.resetForTesting()
            StowerDiagnostics.resetForTesting()
        }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnosticsConsent(storage: storage).setEnabled(true)
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            hooks: StowerDiagnostics.BackendHooks(
                makeAnalyticsClient: { _, _, _ in },
                startCrashReporting: { _ in },
                stopCrashReporting: {}
            )
        )

        var stopCalled = false
        StowerDiagnostics.reconcileLicenseConsent(
            licenseOptOut: false,
            stopCrashReporting: { stopCalled = true }
        )

        #expect(stopCalled == false, "stop must not be called when licenseOptOut is false")
    }
}
