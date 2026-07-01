import Foundation
import Testing

@testable import StowerMacUI

/// The plaintext-`UserDefaults` license store round-trip + clear.
///
/// Each test uses its own ephemeral suite so it never reads or writes the real
/// app domain, and clears it on the way out.
@Suite internal struct StowerLicenseStoreTests {
    /// Makes an isolated defaults suite for one test, pre-cleared.
    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("write then read round-trips the key and instance id")
    internal func roundTrips() {
        let suite = "stower.licensestore.roundtrip"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StowerLicenseStore(defaults: defaults)

        store.write(StowerStoredLicense(key: "KEY-123", instanceID: "inst-9"))

        #expect(store.read() == StowerStoredLicense(key: "KEY-123", instanceID: "inst-9"))
    }

    @Test("an empty store reads nil")
    internal func emptyReadsNil() {
        let suite = "stower.licensestore.empty"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(StowerLicenseStore(defaults: defaults).read() == nil)
    }

    @Test("clear() removes a written license so a subsequent read is nil")
    internal func clearRemovesWrittenLicense() {
        let suite = "stower.licensestore.clear"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StowerLicenseStore(defaults: defaults)
        store.write(StowerStoredLicense(key: "KEY-123", instanceID: "inst-9"))

        store.clear()

        #expect(store.read() == nil)
    }

    @Test("clear() on an already-empty store is a no-op, not a crash")
    internal func clearOnEmptyStoreIsSafe() {
        let suite = "stower.licensestore.clear-empty"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StowerLicenseStore(defaults: defaults)

        store.clear()

        #expect(store.read() == nil)
    }
}
