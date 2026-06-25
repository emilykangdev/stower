import Foundation
import Testing

@testable import StowerMacUI

/// The gate composes client + store correctly: a local `hasStoredLicense` read,
/// a pure `activate` passthrough, and a `persistLicense` write.
@Suite internal struct StowerLemonSqueezyLicenseGateTests {
    private func makeStore(_ suite: String) -> (StowerLicenseStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return (StowerLicenseStore(defaults: defaults), defaults)
    }

    @Test("hasStoredLicense reflects the store; persistLicense writes both fields")
    internal func storeReadWrite() {
        let suite = "stower.gate.store"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = StowerLemonSqueezyLicenseGate(store: store)

        #expect(gate.hasStoredLicense() == false)
        gate.persistLicense(key: "KEY", instanceID: "inst-1")
        #expect(gate.hasStoredLicense())
        #expect(store.read() == StowerStoredLicense(key: "KEY", instanceID: "inst-1"))
    }

    @Test("activate delegates to the client and never persists")
    internal func activateIsPure() async {
        let suite = "stower.gate.activate"
        let (store, defaults) = makeStore(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = StowerLemonSqueezyClient(
            expectedStoreID: 11,
            expectedProductID: 22,
            transport: { _ in
                let url = URL(string: "https://example.invalid")
                let response = url.flatMap {
                    HTTPURLResponse(url: $0, statusCode: 200, httpVersion: nil, headerFields: nil)
                }
                let body =
                    #"{"activated":true,"instance":{"id":"inst-2"},"#
                    + #""meta":{"store_id":11,"product_id":22}}"#
                return (Data(body.utf8), response ?? URLResponse())
            }
        )
        let gate = StowerLemonSqueezyLicenseGate(client: client, store: store)

        let outcome = await gate.activate(key: "KEY")

        #expect(outcome == .activated(instanceID: "inst-2"))
        #expect(gate.hasStoredLicense() == false)  // activate persisted nothing
    }
}
