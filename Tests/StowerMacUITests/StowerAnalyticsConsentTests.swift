import Foundation
import Testing

@testable import StowerMacUI

/// Tests `StowerDiagnosticsConsent`: explicit opt-in, opt-out, "off wins"
/// reconciliation, and the "never auto-re-enables" invariant (JC8).
@Suite(.serialized) @MainActor internal struct StowerAnalyticsConsentTests {

    @Test("fresh install keeps diagnostics off until explicit choice (I4)")
    internal func freshInstallRequiresChoice() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        #expect(consent.isEnabled == false)
        #expect(consent.hasMadeExplicitChoice == false)
    }

    @Test("setEnabled(false) records an explicit opt-out (I4)")
    internal func setEnabledFalseDisables() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)
        #expect(consent.isEnabled == false)
        #expect(consent.hasMadeExplicitChoice == true)
    }

    @Test("setEnabled(true) records an explicit opt-in (I4)")
    internal func setEnabledTrueRe_enables() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)
        consent.setEnabled(true)
        #expect(consent.isEnabled == true)
        #expect(consent.hasMadeExplicitChoice == true)
    }

    @Test("opt-out persists across consent instances (I4)")
    internal func optOutPersistsAcrossInstances() {
        let storage = StowerInMemoryLeaseStorage()
        let consent1 = StowerDiagnosticsConsent(storage: storage)
        consent1.setEnabled(false)
        // Simulating a relaunch by creating a new instance over the same storage.
        let consent2 = StowerDiagnosticsConsent(storage: storage)
        #expect(consent2.isEnabled == false)
    }

    @Test("license opt-out records an explicit disabled choice (I4)")
    internal func reconcileLicenseOptOutTurnsOffCache() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(true)
        #expect(consent.isEnabled == true)

        consent.reconcile(licenseOptOut: true)
        #expect(consent.isEnabled == false)
        #expect(consent.hasMadeExplicitChoice == true)
    }

    @Test("license opt-out disables a no-choice install (I4)")
    internal func reconcileLicenseOptOutTurnsOffNoChoiceCache() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        #expect(consent.hasMadeExplicitChoice == false)

        consent.reconcile(licenseOptOut: true)
        #expect(consent.isEnabled == false)
        #expect(consent.hasMadeExplicitChoice == true)
    }

    @Test("license opt-in never re-enables a local opt-out (I4)")
    internal func reconcileDoesNotReenableIfLicenseIsOn() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)
        // License says NOT opted out — reconcile must not re-enable ("off wins").
        consent.reconcile(licenseOptOut: false)
        #expect(consent.isEnabled == false, "off wins: reconcile must never auto-re-enable")
    }

    @Test("undecodable storage keeps diagnostics off (I4)")
    internal func undecodableStorageDefaultsOff() {
        // UserDefaults holds bytes that fail to decode as a
        // DiagnosticsInstallRecord — treat as no explicit choice.
        StowerDiagnosticsKillLatch.reset()
        defer { StowerDiagnosticsKillLatch.reset() }

        let storage = StowerInMemoryLeaseStorage()
        storage.write(Data("not valid json".utf8))
        let consent = StowerDiagnosticsConsent(storage: storage)

        #expect(
            consent.isEnabled == false,
            "undecodable UserDefaults must not enable diagnostics before consent"
        )
    }

    @Test("migrated default-on records do not count as consent (I4)")
    internal func migratedDefaultOnRecordRequiresChoice() {
        StowerDiagnosticsKillLatch.reset()
        defer { StowerDiagnosticsKillLatch.reset() }

        let storage = StowerInMemoryLeaseStorage()
        storage.write(Data(#"{"id":"00000000-0000-0000-0000-000000000000","enabled":true}"#.utf8))
        let consent = StowerDiagnosticsConsent(storage: storage)

        #expect(consent.isEnabled == false)
        #expect(consent.hasMadeExplicitChoice == false)
    }

    @Test("identity and consent share one install record (I4)")
    internal func identityAndConsentShareSameRecord() {
        let storage = StowerInMemoryLeaseStorage()
        let identity = StowerDiagnosticsIdentity(storage: storage)
        let consent = StowerDiagnosticsConsent(storage: storage)
        let id = identity.clientUser()
        consent.setEnabled(false)
        // After opt-out, the identity UUID must still be readable (same record).
        let idAfterOptOut = identity.clientUser()
        #expect(id == idAfterOptOut)
        #expect(consent.isEnabled == false)
    }
}
