import Foundation
import Testing

@testable import StowerMacUI

/// I2 (state routing) + I6 (offline never strands a trial/paid user).
@Suite internal struct StowerLemonSqueezyLicenseGateTests {
    private func makeStore(_ suite: String) -> (StowerLicenseStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return (StowerLicenseStore(defaults: defaults), defaults)
    }

    private func activatedTransport(
        storeID: Int,
        productID: Int
    ) throws -> StowerLemonSqueezyClient.Transport {
        let url = try #require(URL(string: "https://example.invalid"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        let body =
            #"{"activated":true,"instance":{"id":"inst-2"},"#
            + #""meta":{"store_id":\#(storeID),"product_id":\#(productID)}}"#
        let data = Data(body.utf8)
        return { _ in (data, response) }
    }

    @Test("I2: a stored license routes to .licensed regardless of the trial clock")
    internal func storedLicenseRoutesLicensed() {
        let suite = "stower.lsgate.licensed"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.write(StowerStoredLicense(key: "KEY", instanceID: "inst-1"))
        let gate = StowerLemonSqueezyLicenseGate(
            client: StowerLemonSqueezyClient(expectedStoreID: 1, expectedProductID: 2),
            store: store,
            trialClock: StowerTrialClock(defaults: defaults)
        )

        #expect(gate.licenseState(now: Date()) == .licensed)
    }

    @Test("I2: no stored license + active trial routes to .trial(expiry:)")
    internal func noLicenseActiveTrialRoutesTrial() {
        let suite = "stower.lsgate.trial"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StowerTrialClock(defaults: defaults)
        let gate = StowerLemonSqueezyLicenseGate(
            client: StowerLemonSqueezyClient(expectedStoreID: 1, expectedProductID: 2),
            store: store,
            trialClock: clock
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let state = gate.licenseState(now: now)

        #expect(state == .trial(expiry: now.addingTimeInterval(7 * 24 * 60 * 60)))
    }

    @Test("I2: no stored license + expired trial routes to .expired")
    internal func noLicenseExpiredTrialRoutesExpired() {
        let suite = "stower.lsgate.expired"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StowerTrialClock(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = clock.state(now: now)
        let gate = StowerLemonSqueezyLicenseGate(
            client: StowerLemonSqueezyClient(expectedStoreID: 1, expectedProductID: 2),
            store: store,
            trialClock: clock
        )

        let state = gate.licenseState(now: now.addingTimeInterval(8 * 24 * 60 * 60))

        #expect(state == .expired)
    }

    @Test("activate delegates to the client and never persists")
    internal func activateIsPure() async throws {
        let suite = "stower.lsgate.activate"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = StowerLemonSqueezyClient(
            expectedStoreID: 11,
            expectedProductID: 22,
            transport: try activatedTransport(storeID: 11, productID: 22)
        )
        let gate = StowerLemonSqueezyLicenseGate(
            client: client,
            store: store,
            trialClock: StowerTrialClock(defaults: defaults)
        )

        let outcome = await gate.activate(key: "KEY")

        #expect(outcome == .activated(instanceID: "inst-2"))
        #expect(gate.licenseState(now: Date()) != .licensed)  // activate persisted nothing
    }

    @Test("persist writes the store so a subsequent licenseState reads .licensed")
    internal func persistWritesStore() {
        let suite = "stower.lsgate.persist"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = StowerLemonSqueezyLicenseGate(
            client: StowerLemonSqueezyClient(expectedStoreID: 1, expectedProductID: 2),
            store: store,
            trialClock: StowerTrialClock(defaults: defaults)
        )

        gate.persist(key: "KEY", instanceID: "inst-9")

        #expect(gate.licenseState(now: Date()) == .licensed)
        #expect(store.read() == StowerStoredLicense(key: "KEY", instanceID: "inst-9"))
    }

    @Test("I6: a transport failure classifies as .couldNotReach and never persists")
    internal func offlineActivateDoesNotPersist() async {
        let suite = "stower.lsgate.offline"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        struct TransportFailure: Error {}
        let client = StowerLemonSqueezyClient(
            expectedStoreID: 11,
            expectedProductID: 22,
            transport: { _ in throw TransportFailure() }
        )
        let gate = StowerLemonSqueezyLicenseGate(
            client: client,
            store: store,
            trialClock: StowerTrialClock(defaults: defaults)
        )

        let outcome = await gate.activate(key: "KEY")

        #expect(outcome == .couldNotReach)
        #expect(store.read() == nil)
    }

    @Test("I6: a stored license stays .licensed without ever calling the network for state")
    internal func storedLicenseStaysLicensedOffline() {
        let suite = "stower.lsgate.offline-licensed"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.write(StowerStoredLicense(key: "KEY", instanceID: "inst-1"))
        // A client whose transport would throw if ever invoked — licenseState
        // must never call it.
        struct UnexpectedCall: Error {}
        let client = StowerLemonSqueezyClient(
            expectedStoreID: 1,
            expectedProductID: 2,
            transport: { _ in throw UnexpectedCall() }
        )
        let gate = StowerLemonSqueezyLicenseGate(
            client: client,
            store: store,
            trialClock: StowerTrialClock(defaults: defaults)
        )

        #expect(gate.licenseState(now: Date()) == .licensed)
    }
}
