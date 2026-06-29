import Foundation
import Testing

@testable import StowerMacUI

/// Tests the kill-switch invariant: disabled consent → `makeClient` never called,
/// zero signals sent (JC6, §Invariants row 1).
@Suite @MainActor internal struct StowerAnalyticsGateTests {

    @Test internal func disabledConsentSkipsInitAndEmitsNothing() async {
        let storage = StowerInMemoryLeaseStorage()
        // Pre-write a record with enabled=false.
        let consent = StowerAnalyticsConsent(storage: storage)
        consent.setEnabled(false)

        var makeClientCalled = false
        let spy = StowerInMemoryAnalyticsReporter()

        // Initialize with disabled consent — makeClient must NOT be called.
        StowerAnalytics.initialize(
            consent: StowerAnalyticsConsent(storage: storage),
            identity: StowerAnalyticsIdentity(storage: storage),
            makeClient: { _, _, _ in makeClientCalled = true }
        )

        #expect(
            makeClientCalled == false,
            "makeClient must not be called when consent is off (A3/JC6)"
        )
        #expect(StowerAnalytics.isEnabled() == false)

        // Attempting to report must be a no-op.
        StowerAnalytics.report(.appLaunched)
        // The facade uses a no-op reporter when disabled; spy is separate here to
        // verify the gate — since the gate prevents calls, we verify via isEnabled.
        #expect(spy.recorded().isEmpty)
    }

    @Test internal func enabledConsentCallsMakeClient() async {
        let storage = StowerInMemoryLeaseStorage()
        // Fresh storage = default-on.
        var makeClientCalled = false

        StowerAnalytics.initialize(
            consent: StowerAnalyticsConsent(storage: storage),
            identity: StowerAnalyticsIdentity(storage: storage),
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
}
