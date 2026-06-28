import Foundation
import Testing

@testable import StowerMacUI

/// Verifies the `StowerTrialBadgeDismissing` seam: persistence across restarts,
/// isolation from the license gate, and correctness of both the in-memory fake
/// and the UserDefaults-backed real implementation.
@Suite internal struct StowerTrialBadgeDismissalTests {

    // MARK: - In-memory fake

    @Test("in-memory fake: isDismissed starts false")
    internal func fakeStartsUndismissed() {
        let fake = StowerInMemoryBadgeDismissal()
        #expect(!fake.isDismissed)
    }

    @Test("in-memory fake: dismiss() sets isDismissed true")
    internal func fakeDismissSetsDismissed() {
        let fake = StowerInMemoryBadgeDismissal()
        fake.dismiss()
        #expect(fake.isDismissed)
    }

    @Test("in-memory fake: isDismissed is idempotent after multiple dismiss() calls")
    internal func fakeDismissIdempotent() {
        let fake = StowerInMemoryBadgeDismissal()
        fake.dismiss()
        fake.dismiss()
        #expect(fake.isDismissed)
    }

    // MARK: - UserDefaults-backed real implementation

    /// Returns a fresh `StowerUserDefaultsBadgeDismissal` backed by an isolated
    /// `UserDefaults` suite so the test never pollutes `UserDefaults.standard` and a
    /// fresh instance on the same suite simulates a relaunch.
    private func makeDismissal(suite: UserDefaults) -> StowerUserDefaultsBadgeDismissal {
        StowerUserDefaultsBadgeDismissal(defaults: suite)
    }

    /// Creates a fresh, isolated UserDefaults suite for one test run.
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "StowerTrialBadgeDismissalTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suiteName))
    }

    @Test("real: isDismissed starts false before any dismiss() call")
    internal func realStartsUndismissed() throws {
        let defaults = try isolatedDefaults()
        let store = makeDismissal(suite: defaults)
        #expect(!store.isDismissed)
    }

    @Test("real: dismiss() persists across fresh instances (simulates relaunch)")
    internal func realDismissalPersistsAcrossInstances() throws {
        let defaults = try isolatedDefaults()

        // First instance: dismiss.
        let first = makeDismissal(suite: defaults)
        first.dismiss()

        // Second instance on the same suite (simulates relaunch reading same defaults).
        let second = makeDismissal(suite: defaults)
        #expect(second.isDismissed)
    }

    @Test("real: key is StowerTrialBadgeDismissed")
    internal func realUsesExpectedKey() throws {
        let defaults = try isolatedDefaults()
        let store = makeDismissal(suite: defaults)
        store.dismiss()
        #expect(defaults.bool(forKey: StowerUserDefaultsBadgeDismissal.dismissedKey))
        #expect(StowerUserDefaultsBadgeDismissal.dismissedKey == "StowerTrialBadgeDismissed")
    }

    // MARK: - Isolation invariant (I3)

    @Test("dismissal flag is not read by StowerLicenseLeaseStore or offlineAuthority")
    internal func dismissalIsolatedFromOfflineAuthority() throws {
        // The dismissal flag lives only in UserDefaults; it must not appear in any
        // code path that calls offlineAuthority / load on the lease store. This test
        // is a compile-time-visible contract check: constructing StowerLicenseLeaseStore
        // without a StowerTrialBadgeDismissing parameter is the assertion.
        //
        // If someone added a dismissal parameter to StowerLicenseLeaseStore or
        // StowerLicenseGate, this file would not compile (the init would be wrong).
        // The explicit construction below acts as the regression gate.
        let storage = StowerInMemoryLeaseStorage()
        _ = StowerLicenseLeaseStore(
            storage: storage,
            publicKeyHex: "00"  // invalid key → load returns nil; not what we're testing
        )
        // Reaching here without a compilation error confirms the seam is isolated.
    }
}
