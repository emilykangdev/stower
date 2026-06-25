import Foundation

/// The production `StowerLicenseGating`: composes the activate client and the
/// plaintext store.
///
/// `hasStoredLicense` reads the store, `activate` delegates to the client (pure —
/// no persistence), `persistLicense` writes the store. The `instance_name` label
/// sent to Lemon Squeezy lives here, once.
internal struct StowerLemonSqueezyLicenseGate: StowerLicenseGating {
    private let client: StowerLemonSqueezyClient
    private let store: StowerLicenseStore

    /// Creates the gate.
    ///
    /// - Parameters:
    ///   - client: The activate client; defaults to the real `URLSession` one,
    ///     configured with Stower's expected store/product IDs.
    ///   - store: The plaintext `UserDefaults` store; defaults to `.standard`.
    internal init(
        client: StowerLemonSqueezyClient? = nil,
        store: StowerLicenseStore = StowerLicenseStore()
    ) {
        self.client =
            client
            ?? StowerLemonSqueezyClient(
                expectedStoreID: Self.expectedStoreID,
                expectedProductID: Self.expectedProductID
            )
        self.store = store
    }

    internal func hasStoredLicense() -> Bool {
        store.read() != nil
    }

    internal func activate(key: String) async -> StowerLicenseActivation {
        await client.activate(key: key, instanceName: Self.instanceName)
    }

    internal func persistLicense(key: String, instanceID: String) {
        store.write(StowerStoredLicense(key: key, instanceID: instanceID))
    }

    /// The `instance_name` sent at activation.
    ///
    /// A fixed app label (not the device hostname) keeps any user-identifying
    /// device name out of the one network call.
    private static let instanceName = "Stower"

    /// Stower's Lemon Squeezy `store_id` and `product_id`.
    ///
    /// A key whose activate response does not match BOTH is rejected as
    /// `.invalid` — otherwise a license for any other Lemon Squeezy product would
    /// unlock Stower.
    ///
    /// PLACEHOLDERS — set these to the real dashboard IDs before selling, or no
    /// key will activate (the check fails closed). Find them in the Lemon Squeezy
    /// dashboard (or any activate response's `meta.store_id` / `meta.product_id`).
    private static let expectedStoreID = 0
    private static let expectedProductID = 0
}
