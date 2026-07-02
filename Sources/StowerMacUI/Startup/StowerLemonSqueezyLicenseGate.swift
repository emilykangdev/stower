import Foundation

/// The production `StowerLicenseGating` conformer: composes the Lemon Squeezy
/// activate client, the plaintext license store, and the local trial clock.
///
/// `licenseState`/`persist` are pure local reads/writes (no network);
/// `activate` is the app's only network call. There is no `/validate` /
/// revocation path (JC3) — once activated, the app trusts the local store
/// forever.
internal struct StowerLemonSqueezyLicenseGate: StowerLicenseGating {
    private let client: StowerLemonSqueezyClient
    private let store: StowerLicenseStore
    private let trialClock: StowerTrialClock

    /// The device label sent as `instance_name` on activation.
    private let instanceName: String

    /// Creates the gate from its collaborators (tests pass their own doubles).
    ///
    /// - Parameters:
    ///   - client: The Lemon Squeezy activate client.
    ///   - store: The license store.
    ///   - trialClock: The trial clock.
    ///   - instanceName: The `instance_name` label; defaults to "Stower".
    internal init(
        client: StowerLemonSqueezyClient,
        store: StowerLicenseStore,
        trialClock: StowerTrialClock,
        instanceName: String = Self.defaultInstanceName
    ) {
        self.client = client
        self.store = store
        self.trialClock = trialClock
        self.instanceName = instanceName
    }

    /// Builds the production gate from `StowerLicenseConfig.resolved` and the
    /// standard-domain store/clock.
    ///
    /// In a DEBUG build, the `StowerLicenseDebugArguments` launch-arg seam can
    /// clear the stored license (`--clear-license`) and reset the trial clock
    /// (`--reset-trial`) before the gate is constructed; the whole seam is
    /// compile-stripped from Release.
    internal init() {
        let store = StowerLicenseStore()
        let trialClock = StowerTrialClock()
        #if DEBUG
            let debug = StowerLicenseDebugArguments.parse(CommandLine.arguments)
            if debug.clearLicense { store.clear() }
            if debug.resetTrial { trialClock.reset() }
        #endif
        self.init(
            client: StowerLemonSqueezyClient(
                expectedStoreID: StowerLicenseConfig.resolved.storeID,
                expectedProductID: StowerLicenseConfig.resolved.productID
            ),
            store: store,
            trialClock: trialClock
        )
    }

    internal func isFirstTrialObservation(now: Date) -> Bool {
        guard store.read() == nil else { return false }
        return !trialClock.hasSeededFirstLaunch
    }

    internal func licenseState(now: Date) -> StowerLicenseState {
        guard store.read() == nil else { return .licensed }
        switch trialClock.state(now: now) {
        case .active(let expiry):
            return .trial(expiry: expiry)
        case .expired:
            return .expired
        }
    }

    internal func activate(key: String) async -> StowerLicenseActivation {
        await client.activate(key: key, instanceName: instanceName)
    }

    internal func persist(key: String, instanceID: String) {
        store.write(StowerStoredLicense(key: key, instanceID: instanceID))
    }

    private static let defaultInstanceName = "Stower"
}
