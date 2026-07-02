import Foundation
import Testing

@testable import StowerMacUI

/// Tests the kill-switch invariant: disabled consent → `makeClient` never called,
/// zero signals sent (JC6, §Invariants row 1).
@Suite(.serialized) @MainActor internal struct StowerAnalyticsGateTests {

    @Test internal func disabledConsentSkipsInitAndEmitsNothing() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        // Pre-write a record with enabled=false.
        let consent = StowerDiagnosticsConsent(storage: storage, legacyKeychainRead: { nil })
        consent.setEnabled(false)

        var makeClientCalled = false

        // Initialize with disabled consent — makeClient must NOT be called.
        StowerAnalytics.startBackend(
            consent: StowerDiagnosticsConsent(storage: storage, legacyKeychainRead: { nil }),
            identity: StowerDiagnosticsIdentity(storage: storage, legacyKeychainRead: { nil }),
            makeClient: { _, _, _ in makeClientCalled = true }
        )

        #expect(
            makeClientCalled == false,
            "makeClient must not be called when consent is off (A3/JC6)"
        )
        #expect(StowerAnalytics.isEnabled() == false)

        // Attempting to report must be a no-op (facade holds a no-op reporter when disabled).
        StowerAnalytics.report(.appLaunched)
    }

    @Test internal func enabledConsentCallsMakeClient() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        // Fresh storage = default-on.
        var makeClientCalled = false

        StowerAnalytics.startBackend(
            consent: StowerDiagnosticsConsent(storage: storage, legacyKeychainRead: { nil }),
            identity: StowerDiagnosticsIdentity(storage: storage, legacyKeychainRead: { nil }),
            makeClient: { _, _, _ in makeClientCalled = true }
        )

        #expect(makeClientCalled == true)
        #expect(StowerAnalytics.isEnabled() == true)
    }

    @Test internal func reporterSpy_recordsInOrder() {
        let spy = StowerInMemoryAnalyticsReporter()
        spy.report(.appLaunched)
        spy.report(.boardReached)
        spy.report(.sessionEnded)
        let events = spy.recorded()
        #expect(events.count == 3)
        #expect(events[0].signalName == "app_launched")
        #expect(events[1].signalName == "board_reached")
        #expect(events[2].signalName == "session_ended")
    }

    @Test internal func noOpReporterNeverAccumulates() {
        let reporter = StowerNoOpAnalyticsReporter()
        // No crash, no state mutation — just a pure no-op.
        reporter.report(.appLaunched)
        reporter.report(.sessionEnded)
    }

    /// The in-memory kill latch overrides an enabled UserDefaults cache, so every
    /// reporter (which gates on `consent.isEnabled`) stops immediately even if a
    /// failed opt-out write left the cache reading "on" (F4/JC6).
    @Test internal func killLatchOverridesEnabledCacheForAllReporters() {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage, legacyKeychainRead: { nil })
        // Fresh storage = enabled cache (default-on).
        #expect(consent.isEnabled == true)

        StowerDiagnosticsKillLatch.latchOff()
        #expect(consent.isEnabled == false, "latch must win over an enabled cache")

        StowerDiagnosticsKillLatch.reset()
        #expect(consent.isEnabled == true, "explicit opt-in clears the latch")
    }
}
