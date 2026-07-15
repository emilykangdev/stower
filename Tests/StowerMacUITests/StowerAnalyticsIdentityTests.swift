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

    @Test("identity creation does not grant diagnostics consent (I4)")
    internal func identityCreationDoesNotGrantConsent() {
        let storage = StowerInMemoryLeaseStorage()
        _ = StowerDiagnosticsIdentity(storage: storage).clientUser()
        let consent = StowerDiagnosticsConsent(storage: storage)
        #expect(consent.isEnabled == false)
        #expect(consent.hasMadeExplicitChoice == false)
    }

    @Test("undecodable storage mints a fresh valid identity (I4)")
    internal func undecodableStorageMintsFreshIdentity() {
        // UserDefaults holds bytes that fail to decode as a
        // DiagnosticsInstallRecord — treat as a fresh install and mint a valid
        // UUID rather than crashing or returning garbage.
        let storage = StowerInMemoryLeaseStorage()
        storage.write(Data("not valid json".utf8))

        let identity = StowerDiagnosticsIdentity(storage: storage)
        let returned = identity.clientUser()

        #expect(
            UUID(uuidString: returned) != nil,
            "undecodable storage must mint a valid UUID, not return garbage"
        )
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
