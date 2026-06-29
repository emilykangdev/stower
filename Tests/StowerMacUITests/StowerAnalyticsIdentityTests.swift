import Foundation
import Testing

@testable import StowerMacUI

/// Tests `StowerAnalyticsIdentity`: stability, fresh-UUID minting, and
/// service/account non-collision with the license lease.
@Suite internal struct StowerAnalyticsIdentityTests {

    @Test internal func returnsStableIDOnMultipleCalls() {
        let storage = StowerInMemoryLeaseStorage()
        let identity = StowerAnalyticsIdentity(storage: storage)
        let first = identity.clientUser()
        let second = identity.clientUser()
        #expect(first == second)
    }

    @Test internal func survivesFreshStorageReinit() {
        let storage = StowerInMemoryLeaseStorage()
        let id1 = StowerAnalyticsIdentity(storage: storage).clientUser()
        // Simulating a reinstall with the same backing storage (Keychain survives).
        let id2 = StowerAnalyticsIdentity(storage: storage).clientUser()
        #expect(id1 == id2)
    }

    @Test internal func mintsValidUUIDOnFreshStorage() {
        let storage = StowerInMemoryLeaseStorage()
        let id = StowerAnalyticsIdentity(storage: storage).clientUser()
        #expect(UUID(uuidString: id) != nil, "clientUser() must return a valid UUID string")
    }

    @Test internal func analyticsAndLeaseKeychainItemsNeverCollide() {
        // The analytics service/account must differ from the license lease pair.
        #expect(StowerAnalyticsKeychainKeys.service != "com.stower.license.lease")
        #expect(StowerAnalyticsKeychainKeys.account != "machine-file")
    }

    @Test internal func freshStorageDefaultsEnabled() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerAnalyticsConsent(storage: storage)
        // Default-on for a fresh install.
        #expect(consent.isEnabled == true)
    }
}
