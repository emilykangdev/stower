import Foundation
import Testing

@testable import StowerMacUI

/// Tests `StowerDiagnosticsConsent`: enabled default, opt-out, "off wins"
/// reconciliation, and the "never auto-re-enables" invariant (JC8).
@Suite internal struct StowerAnalyticsConsentTests {

    @Test internal func defaultsOnForFreshInstall() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        #expect(consent.isEnabled == true)
    }

    @Test internal func setEnabledFalseDisables() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)
        #expect(consent.isEnabled == false)
    }

    @Test internal func setEnabledTrueRe_enables() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)
        consent.setEnabled(true)
        #expect(consent.isEnabled == true)
    }

    @Test internal func optOutPersistsAcrossInstances() {
        let storage = StowerInMemoryLeaseStorage()
        let consent1 = StowerDiagnosticsConsent(storage: storage)
        consent1.setEnabled(false)
        // Simulating a relaunch by creating a new instance over the same storage.
        let consent2 = StowerDiagnosticsConsent(storage: storage)
        #expect(consent2.isEnabled == false)
    }

    @Test internal func reconcileLicenseOptOutTurnsOffCache() {
        let storage = StowerInMemoryLeaseStorage()
        // Seed a fresh record with enabled=true (simulates wiped storage).
        let identity = StowerDiagnosticsIdentity(storage: storage)
        _ = identity.clientUser()  // mints record with enabled=true
        let consent = StowerDiagnosticsConsent(storage: storage)
        #expect(consent.isEnabled == true)
        // License says opted out — reconcile must turn off the cache.
        consent.reconcile(licenseOptOut: true)
        #expect(consent.isEnabled == false)
    }

    @Test internal func reconcileDoesNotReenableIfLicenseIsOn() {
        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)
        // License says NOT opted out — reconcile must not re-enable ("off wins").
        consent.reconcile(licenseOptOut: false)
        #expect(consent.isEnabled == false, "off wins: reconcile must never auto-re-enable")
    }

    @Test internal func identityAndConsentShareSameRecord() {
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
