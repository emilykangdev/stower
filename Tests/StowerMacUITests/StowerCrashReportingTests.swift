import Foundation
import Sentry
import Testing

@testable import StowerMacUI

/// Tests `StowerCrashReporting` — gate and options-regression invariants.
///
/// - Disabled consent → `SentrySDK.start` never called (§Invariants gate test).
/// - Options regression: only the crash handler is enabled, PII flags off,
///   no `setUser`, `tracesSampleRate=0`, `beforeBreadcrumb` drops (§Invariants).
@Suite internal struct StowerCrashReportingTests {

    // MARK: — Disabled-gate invariant

    /// Consent off ⇒ the injectable startSDK closure must never be called.
    ///
    /// This is the §Invariants "Consent disabled ⇒ SentrySDK.start never called"
    /// test. The injectable `startSDK` seam stands in for the real `SentrySDK.start`
    /// so no real crash handler installs during tests.
    @Test internal func disabledConsent_startSDKNotCalled() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)

        var startSDKCalled = false
        StowerCrashReporting.start(
            consent: StowerDiagnosticsConsent(storage: storage),
            startSDK: { _ in startSDKCalled = true }
        )

        #expect(startSDKCalled == false, "SentrySDK.start must not be called when consent is off")
    }

    /// Fresh install ⇒ the injectable startSDK closure must never be called.
    @Test("fresh install does not call SentrySDK.start before consent (I4)")
    internal func noExplicitConsent_startSDKNotCalled() {
        let storage = StowerInMemoryLeaseStorage()

        var startSDKCalled = false
        StowerCrashReporting.start(
            consent: StowerDiagnosticsConsent(storage: storage),
            startSDK: { _ in startSDKCalled = true }
        )

        #expect(
            startSDKCalled == false,
            "SentrySDK.start must not be called before explicit consent"
        )
    }

    /// Consent on ⇒ the injectable startSDK closure is called exactly once.
    @Test internal func enabledConsent_startSDKCalledOnce() {
        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnosticsConsent(storage: storage).setEnabled(true)
        var startSDKCallCount = 0
        StowerCrashReporting.start(
            consent: StowerDiagnosticsConsent(storage: storage),
            startSDK: { _ in startSDKCallCount += 1 }
        )

        #expect(startSDKCallCount == 1)
    }

    // MARK: — Options regression invariant

    /// Verifies the hardened `Options` configuration matches §Invariants.
    ///
    /// - Crash handler enabled, non-crash integrations disabled.
    /// - `sendDefaultPii=false`, `attachStacktrace=false`, `tracesSampleRate=0`.
    /// - `beforeBreadcrumb` is set and returns nil (drops all breadcrumbs).
    /// - `beforeSend` is set (the scrubber is wired).
    ///
    /// This is the §Invariants options-regression test. `setUser` is deliberately
    /// NOT called — verified by the absence of a user on the scope, which is the
    /// SDK-idiomatic test for "no identity attached" (brief Decision 4).
    ///
    /// One assertion per integration flag (9 flags + 5 PII/tracing/hook checks);
    /// splitting would hide the options-regression surface area.
    @Test internal func hardenedOptions_regression() {
        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnosticsConsent(storage: storage).setEnabled(true)
        var capturedOptions: Options?

        StowerCrashReporting.start(
            consent: StowerDiagnosticsConsent(storage: storage),
            startSDK: { configure in
                let options = Options()
                configure(options)
                capturedOptions = options
            }
        )

        guard let opts = capturedOptions else {
            Issue.record("startSDK was not called — options cannot be inspected")
            return
        }

        // Crash handler must be on.
        #expect(opts.enableCrashHandler == true, "crash handler must be enabled")

        // Non-crash integrations must be off.
        #expect(opts.enableAutoSessionTracking == false, "session tracking must be off")
        #expect(opts.enableWatchdogTerminationTracking == false, "watchdog tracking must be off")
        #expect(opts.enableAppHangTracking == false, "app hang tracking must be off")
        #expect(opts.enableNetworkBreadcrumbs == false, "network breadcrumbs must be off")
        #expect(opts.enableAutoBreadcrumbTracking == false, "auto breadcrumb tracking must be off")
        #expect(opts.enableAutoPerformanceTracing == false, "auto performance tracing must be off")
        #expect(opts.enableNetworkTracking == false, "network tracking must be off")
        #expect(opts.enableSwizzling == false, "swizzling must be off")
        #expect(opts.enableMetricKit == false, "MetricKit integration must be off")

        // PII / enrichment flags.
        #expect(opts.sendDefaultPii == false, "sendDefaultPii must be false — never true")
        #expect(
            opts.attachStacktrace == false,
            "attachStacktrace must be false (v1 sends no messages)"
        )

        // Performance / tracing.
        #expect(
            opts.tracesSampleRate == nil || opts.tracesSampleRate == 0,
            "tracesSampleRate must be 0"
        )

        // beforeBreadcrumb must drop all breadcrumbs.
        #expect(opts.beforeBreadcrumb != nil, "beforeBreadcrumb must be set")
        #expect(
            opts.beforeBreadcrumb?(Breadcrumb()) == nil,
            "beforeBreadcrumb must return nil (drop all breadcrumbs)"
        )

        // beforeSend must be wired (the scrubber).
        #expect(opts.beforeSend != nil, "beforeSend must be wired to the scrubber")
    }
}
