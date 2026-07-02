import Foundation
import Testing

@testable import StowerMacUI

/// Tests `StowerDiagnosticsIdentity`: stability, fresh-UUID minting, and
/// storage-key non-collision with the disclosure shown flag.
@Suite internal struct StowerAnalyticsIdentityTests {

    @Test internal func returnsStableIDOnMultipleCalls() {
        let storage = StowerInMemoryLeaseStorage()
        let identity = StowerDiagnosticsIdentity(storage: storage)
        let first = identity.clientUser()
        let second = identity.clientUser()
        #expect(first == second)
    }

    @Test internal func survivesFreshStorageReinit() {
        let storage = StowerInMemoryLeaseStorage()
        let id1 = StowerDiagnosticsIdentity(storage: storage).clientUser()
        // Simulating a reinstall with the same backing storage (UserDefaults survives).
        let id2 = StowerDiagnosticsIdentity(storage: storage).clientUser()
        #expect(id1 == id2)
    }

    @Test internal func mintsValidUUIDOnFreshStorage() {
        let storage = StowerInMemoryLeaseStorage()
        let id = StowerDiagnosticsIdentity(storage: storage).clientUser()
        #expect(UUID(uuidString: id) != nil, "clientUser() must return a valid UUID string")
    }

    @Test internal func analyticsStorageKeyNeverCollidesWithShownFlag() {
        // The install-record blob key must differ from the disclosure "shown"
        // flag key — both live in UserDefaults, so a collision would corrupt one.
        let recordKey = StowerDiagnosticsStorageLocation.defaultsKey
        let shownKey = StowerDiagnosticsConsent.shownDefaultsKey
        #expect(recordKey != shownKey)
    }

    @Test internal func freshStorageDefaultsEnabled() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        // Default-on for a fresh install.
        #expect(consent.isEnabled == true)
    }

    @Test internal func garbageIDTreatedAsFreshInstall() throws {
        // Pre-write a record whose `id` is not a valid UUID (simulating corruption).
        let storage = StowerInMemoryLeaseStorage()
        let garbled = Data(#"{"id":"not-a-uuid","enabled":true}"#.utf8)
        storage.write(garbled)

        let identity = StowerDiagnosticsIdentity(storage: storage)
        let returned = identity.clientUser()

        // The garbage id must be rejected and a new valid UUID minted.
        #expect(
            returned != "not-a-uuid",
            "clientUser() must not return a garbage id from a corrupted record"
        )
        #expect(
            UUID(uuidString: returned) != nil,
            "clientUser() must always return a valid UUID string"
        )
    }
}
