import Foundation
import Testing

@testable import StowerMacUI

/// The metadata factory: a trial user with no stored license yields
/// `instanceID: nil` and `.trial`; a paid user with a stored instance id yields
/// that id and `.paid` (I-TrialNullInstance).
@Suite internal struct StowerFeedbackMetadataTests {

    /// A `StowerLicenseStore` over an ephemeral, isolated defaults suite so the
    /// real license domain is never touched.
    private func store(seed license: StowerStoredLicense? = nil) throws -> StowerLicenseStore {
        let suiteName = "stower.feedback.metadata.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = StowerLicenseStore(defaults: defaults)
        if let license { store.write(license) }
        return store
    }

    @Test("I-TrialNullInstance: a trial user with no stored license → nil instanceID, .trial")
    internal func trialHasNoInstanceID() throws {
        let metadata = StowerFeedbackMetadata.current(
            isOnTrial: true,
            licenseStore: try store(),
            bundle: StowerFakeBundle(version: "1.0 (1)"),
            processInfo: StowerFakeOS(os: "macOS 15.4")
        )
        #expect(metadata.instanceID == nil)
        #expect(metadata.licenseStatus == .trial)
        #expect(metadata.appVersion == "1.0 (1)")
        #expect(metadata.osVersion == "macOS 15.4")
    }

    @Test("a paid user with a stored instance id → that id, .paid")
    internal func paidCarriesInstanceID() throws {
        let seeded = StowerStoredLicense(key: "the-secret-key", instanceID: "inst-99")
        let metadata = StowerFeedbackMetadata.current(
            isOnTrial: false,
            licenseStore: try store(seed: seeded),
            bundle: StowerFakeBundle(version: "1.0 (1)"),
            processInfo: StowerFakeOS(os: "macOS 15.4")
        )
        #expect(metadata.instanceID == "inst-99")
        #expect(metadata.licenseStatus == .paid)
    }

    @Test("not on trial with no stored license → defensive .unlicensed, nil instanceID")
    internal func noTrialNoLicenseIsUnlicensed() throws {
        let metadata = StowerFeedbackMetadata.current(
            isOnTrial: false,
            licenseStore: try store(),
            bundle: StowerFakeBundle(version: "1.0 (1)"),
            processInfo: StowerFakeOS(os: "macOS 15.4")
        )
        #expect(metadata.instanceID == nil)
        #expect(metadata.licenseStatus == .unlicensed)
    }
}

/// A fixed app-version reader so tests never depend on `Bundle.main` (which under
/// `swift test` is the test runner, not StowerMac).
private struct StowerFakeBundle: StowerFeedbackBundleReading {
    let version: String
    var stowerVersionString: String { version }
}

/// A fixed OS-version reader.
private struct StowerFakeOS: StowerFeedbackOSReading {
    let os: String
    var stowerOSVersionString: String { os }
}
