import Foundation
import Synchronization
import Testing

@testable import StowerMacUI

/// Tests `StowerDiagnosticsIdentity`: stability, fresh-UUID minting, and
/// storage-key non-collision with the disclosure shown flag.
@Suite internal struct StowerAnalyticsIdentityTests {

    @Test internal func returnsStableIDOnMultipleCalls() {
        let storage = StowerInMemoryLeaseStorage()
        let identity = StowerDiagnosticsIdentity(storage: storage, legacyKeychainRead: { nil })
        let first = identity.clientUser()
        let second = identity.clientUser()
        #expect(first == second)
    }

    @Test internal func survivesFreshStorageReinit() {
        let storage = StowerInMemoryLeaseStorage()
        let id1 = StowerDiagnosticsIdentity(
            storage: storage,
            legacyKeychainRead: { nil }
        ).clientUser()
        // Simulating a reinstall with the same backing storage (UserDefaults survives).
        let id2 = StowerDiagnosticsIdentity(
            storage: storage,
            legacyKeychainRead: { nil }
        ).clientUser()
        #expect(id1 == id2)
    }

    @Test internal func mintsValidUUIDOnFreshStorage() {
        let storage = StowerInMemoryLeaseStorage()
        let id = StowerDiagnosticsIdentity(
            storage: storage,
            legacyKeychainRead: { nil }
        ).clientUser()
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

    @Test internal func migratesLegacyKeychainRecordWhenStorageIsEmpty() throws {
        // An upgrading install: nothing in UserDefaults yet, but the pre-migration
        // Keychain item holds the real record — including a prior opt-out.
        let legacyID = UUID().uuidString
        let legacyRecord = try JSONEncoder().encode(
            DiagnosticsInstallRecord(id: legacyID, enabled: false)
        )
        let storage = StowerInMemoryLeaseStorage()
        let identity = StowerDiagnosticsIdentity(
            storage: storage,
            legacyKeychainRead: { legacyRecord }
        )

        let returned = identity.clientUser()

        #expect(
            returned == legacyID,
            "an upgrading install must keep its pre-migration identity, not mint a fresh one"
        )
        // The migration must persist forward, not just return the value in memory.
        let persisted = try #require(storage.readData())
        let decoded = try JSONDecoder().decode(DiagnosticsInstallRecord.self, from: persisted)
        #expect(decoded.id == legacyID)
        #expect(
            decoded.enabled == false,
            "a prior opt-out must survive the migration, not silently reset to default-on"
        )
    }

    @Test internal func legacyKeychainOnlyReadOncePerInstall() throws {
        // After the first `clientUser()` migrates the record into `storage`,
        // a second call must never touch the legacy read again — it should
        // already be satisfied by `storedRecord()`.
        let legacyRecord = try JSONEncoder().encode(
            DiagnosticsInstallRecord(id: UUID().uuidString, enabled: true)
        )
        let legacyReadCount = Mutex(0)
        let storage = StowerInMemoryLeaseStorage()
        let identity = StowerDiagnosticsIdentity(
            storage: storage,
            legacyKeychainRead: {
                legacyReadCount.withLock { $0 += 1 }
                return legacyRecord
            }
        )

        let first = identity.clientUser()
        let second = identity.clientUser()

        #expect(first == second)
        #expect(legacyReadCount.withLock { $0 } == 1)
    }

    @Test internal func garbageIDTreatedAsFreshInstall() throws {
        // Pre-write a record whose `id` is not a valid UUID (simulating corruption).
        let storage = StowerInMemoryLeaseStorage()
        let garbled = Data(#"{"id":"not-a-uuid","enabled":true}"#.utf8)
        storage.write(garbled)

        let identity = StowerDiagnosticsIdentity(storage: storage, legacyKeychainRead: { nil })
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
