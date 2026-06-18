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
    ///   - client: The activate client; defaults to the real `URLSession` one.
    ///   - store: The plaintext `UserDefaults` store; defaults to `.standard`.
    internal init(
        client: StowerLemonSqueezyClient = StowerLemonSqueezyClient(),
        store: StowerLicenseStore = StowerLicenseStore()
    ) {
        self.client = client
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
}
