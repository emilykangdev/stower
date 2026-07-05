import Foundation
import Testing

@testable import StowerMacUI

/// Tests the `StowerDiagnostics` umbrella facade: disabled consent → neither
/// backend starts; one consent switch governs both backends (A6/JC3).
@Suite(.serialized) @MainActor internal struct StowerDiagnosticsGateTests {

    @Test internal func disabledConsent_neitherBackendStarts() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)

        var analyticsClientCalled = false

        // Drive StowerDiagnostics.initialize with a disabled consent — neither
        // backend should fire (A6/JC3: one gate governs both).
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in analyticsClientCalled = true }
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
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        // Fresh storage = default-on.
        var analyticsClientCalled = false

        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in analyticsClientCalled = true }
        )

        #expect(analyticsClientCalled == true, "analytics backend must start when consent is on")
        #expect(StowerDiagnostics.isEnabled() == true)
    }

    @Test internal func setEnabled_false_disablesDiagnostics() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in }
        )
        #expect(StowerDiagnostics.isEnabled() == true)

        StowerDiagnostics.setEnabled(false)

        #expect(StowerDiagnostics.isEnabled() == false)
    }

    @Test internal func reconcileLicenseConsent_propagates() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in }
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
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in }
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
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in }
        )

        var stopCalled = false
        StowerDiagnostics.reconcileLicenseConsent(
            licenseOptOut: false,
            stopCrashReporting: { stopCalled = true }
        )

        #expect(stopCalled == false, "stop must not be called when licenseOptOut is false")
    }
}
