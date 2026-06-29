import CryptoKit
import Foundation
import Testing

@testable import StowerMacUI

/// The lease store round-trips a lease and rejects a tampered machine-file whose
/// Ed25519 signature no longer verifies (I7) — driven by an in-memory blob and a
/// known signing key, never the real Keychain or the embedded production key.
@Suite internal struct StowerLicenseLeaseStoreTests {
    private let signingKey = Curve25519.Signing.PrivateKey()
    /// An arbitrary base64 payload; the verifier signs over `"machine/" + enc`
    /// and never decodes `enc`, so its contents do not matter.
    private let enc = "eyJ0ZXN0IjoxfQ=="

    private typealias InMemoryLeaseStorage = StowerInMemoryLeaseStorage

    /// A store wired to a fresh in-memory blob and this suite's public key.
    private func makeStore(_ storage: StowerLeaseStorage) -> StowerLicenseLeaseStore {
        StowerLicenseLeaseStore(
            storage: storage,
            publicKeyHex: signingKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        )
    }

    /// Wraps `enc`/`sig` in the PEM machine-file envelope the store parses.
    private func machineFile(enc: String, sig: String) -> String {
        let json = #"{"enc":"\#(enc)","sig":"\#(sig)","alg":"base64+ed25519"}"#
        let body = Data(json.utf8).base64EncodedString()
        return "-----BEGIN MACHINE FILE-----\n\(body)\n-----END MACHINE FILE-----"
    }

    /// A correctly-signed machine-file over this suite's `enc`.
    private func validMachineFile() throws -> String {
        let signature = try signingKey.signature(for: Data(("machine/" + enc).utf8))
        return machineFile(enc: enc, sig: signature.base64EncodedString())
    }

    /// A correctly-signed machine-file whose `enc` is the base64 of `payload` — a
    /// Keygen machine-file body (`{meta:{expiry}, included:[…]}`) the offline
    /// accessor decodes.
    private func signedMachineFile(payload: String) throws -> String {
        let payloadEnc = Data(payload.utf8).base64EncodedString()
        let signature = try signingKey.signature(for: Data(("machine/" + payloadEnc).utf8))
        return machineFile(enc: payloadEnc, sig: signature.base64EncodedString())
    }

    /// A machine-file `enc` body with `expiry` and the given entitlement `codes`.
    private func payload(expiry: String, codes: [String]) -> String {
        let entitlements =
            codes
            .map { #"{"type":"entitlements","attributes":{"code":"\#($0)"}}"# }
            .joined(separator: ",")
        return #"{"meta":{"expiry":"\#(expiry)"},"included":[\#(entitlements),"#
            + #"{"type":"licenses","attributes":{"expiry":"2030-01-01T00:00:00.000Z"}}]}"#
    }

    /// A fixed "now" before the future expiries and after the past ones.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let futureExpiry = "2030-01-01T00:00:00.000Z"
    private let pastExpiry = "2020-01-01T00:00:00.000Z"

    private func lease(machineFile: String) -> StowerLicenseLease {
        StowerLicenseLease(
            licenseKey: "KEY",
            licenseID: "lic",
            machineFile: machineFile,
            validatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test("save then load round-trips a verified lease")
    internal func roundTripsValidLease() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let lease = StowerLicenseLease(
            licenseKey: "KEY-123",
            licenseID: "lic-9",
            machineFile: try validMachineFile(),
            validatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(store.save(lease))
        #expect(store.load() == lease)
    }

    @Test("a tampered machine-file fails the signature check and loads as nil")
    internal func rejectsTamperedMachineFile() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let signature = try signingKey.signature(for: Data(("machine/" + enc).utf8))
        // The signature covers `enc`, but the published file carries a different
        // `enc`, so verification fails.
        let tampered = machineFile(enc: enc + "AA", sig: signature.base64EncodedString())
        let lease = StowerLicenseLease(
            licenseKey: "KEY-123",
            licenseID: "lic-9",
            machineFile: tampered,
            validatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(store.save(lease))
        #expect(store.load() == nil)
        #expect(store.verifyMachineFile(try validMachineFile()))
        #expect(!store.verifyMachineFile(tampered))
    }

    @Test("offlineAuthority surfaces machineFileExpiry and entitlement codes from the signed enc")
    internal func offlineAuthoritySurfacesSignedData() throws {
        let storage = InMemoryLeaseStorage()
        let store = makeStore(storage)
        let file = try signedMachineFile(
            payload: payload(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
        )
        store.save(lease(machineFile: file))

        let authority = try #require(store.offlineAuthority(now: now))
        #expect(authority.entitlementCodes == ["STOWER_TRIAL"])
        #expect(authority.allowsThisBuild)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(authority.machineFileExpiry == formatter.date(from: futureExpiry))
    }

    @Test("offlineAuthority is nil once the machine-file TTL has passed (I14, no grace)")
    internal func offlineAuthorityNilAfterTTL() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payload(expiry: pastExpiry, codes: ["STOWER_TRIAL"])
        )
        store.save(lease(machineFile: file))
        #expect(store.offlineAuthority(now: now) == nil)
    }

    @Test("offlineAuthority allowsThisBuild is false without STOWER_TRIAL/STOWER_V0 (I5)")
    internal func offlineAuthorityRejectsWrongEntitlements() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payload(expiry: futureExpiry, codes: ["STOWER_LEGACY"])
        )
        store.save(lease(machineFile: file))

        let authority = try #require(store.offlineAuthority(now: now))
        #expect(!authority.allowsThisBuild)
    }

    @Test("offlineAuthority accepts a STOWER_V0 lease")
    internal func offlineAuthorityAcceptsV0() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payload(expiry: futureExpiry, codes: ["STOWER_V0"])
        )
        store.save(lease(machineFile: file))
        #expect(try #require(store.offlineAuthority(now: now)).allowsThisBuild)
    }

    @Test("offlineAuthority is nil for a tampered machine-file")
    internal func offlineAuthorityNilForTamperedFile() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let payloadEnc = Data(payload(expiry: futureExpiry, codes: ["STOWER_TRIAL"]).utf8)
            .base64EncodedString()
        let signature = try signingKey.signature(for: Data(("machine/" + payloadEnc).utf8))
        // The signature covers the real payload, but the file carries a mutated one.
        let tampered = machineFile(enc: payloadEnc + "AA", sig: signature.base64EncodedString())
        store.save(lease(machineFile: tampered))
        #expect(store.offlineAuthority(now: now) == nil)
    }

    // MARK: - trialExpiry(forLicenseID:) — Task 2

    /// A machine-file `enc` body with a named license entry keyed by `licenseID`.
    ///
    /// Used by the `trialExpiry` tests, which require `id`-matching. The
    /// existing `payload(expiry:codes:)` helper is kept unchanged so that the
    /// `offlineAuthority` tests above remain unmodified.
    private func payloadWithLicenseID(
        metaExpiry: String,
        licenseID: String,
        licenseExpiry: String?,
        extraLicenseIDs: [(id: String, expiry: String?)] = []
    ) -> String {
        let licenseExpiryJSON: String
        if let exp = licenseExpiry {
            licenseExpiryJSON =
                #"{"type":"licenses","id":"\#(licenseID)","attributes":{"expiry":"\#(exp)"}}"#
        } else {
            licenseExpiryJSON =
                #"{"type":"licenses","id":"\#(licenseID)","attributes":{"expiry":null}}"#
        }
        let extras = extraLicenseIDs.map { entry -> String in
            if let exp = entry.expiry {
                return #"{"type":"licenses","id":"\#(entry.id)","attributes":{"expiry":"\#(exp)"}}"#
            } else {
                return #"{"type":"licenses","id":"\#(entry.id)","attributes":{"expiry":null}}"#
            }
        }
        let allIncluded = ([licenseExpiryJSON] + extras).joined(separator: ",")
        return #"{"meta":{"expiry":"\#(metaExpiry)"},"included":[\#(allIncluded)]}"#
    }

    @Test("trialExpiry returns id-matched license expiry, distinct from meta.expiry")
    internal func trialExpiryReturnsIdMatchedExpiry() throws {
        let licenseExpiry = "2026-07-28T00:00:00.000Z"
        let metaExpiry = "2026-07-05T00:00:00.000Z"
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payloadWithLicenseID(
                metaExpiry: metaExpiry,
                licenseID: "lic-A",
                licenseExpiry: licenseExpiry
            )
        )
        store.save(lease(machineFile: file))

        let expiry = try #require(store.trialExpiry(forLicenseID: "lic-A"))
        // Must match the license expiry, NOT the meta expiry.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(expiry == formatter.date(from: licenseExpiry))
        #expect(expiry != formatter.date(from: metaExpiry))
    }

    @Test("trialExpiry returns the id-matched entry when two license entries are present")
    internal func trialExpiryMatchesByID() throws {
        let expiryA = "2026-07-28T00:00:00.000Z"
        let expiryB = "2026-08-15T00:00:00.000Z"
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payloadWithLicenseID(
                metaExpiry: futureExpiry,
                licenseID: "lic-A",
                licenseExpiry: expiryA,
                extraLicenseIDs: [(id: "lic-B", expiry: expiryB)]
            )
        )
        store.save(lease(machineFile: file))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Requesting lic-A returns expiry A.
        #expect(try store.trialExpiry(forLicenseID: "lic-A") == formatter.date(from: expiryA))
        // Requesting lic-B returns expiry B, not A.
        #expect(try store.trialExpiry(forLicenseID: "lic-B") == formatter.date(from: expiryB))
    }

    @Test("trialExpiry is nil when license expiry is null (paid/perpetual)")
    internal func trialExpiryNilWhenLicenseExpiryNull() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payloadWithLicenseID(
                metaExpiry: futureExpiry,
                licenseID: "lic-paid",
                licenseExpiry: nil  // null = paid
            )
        )
        store.save(lease(machineFile: file))
        #expect(store.trialExpiry(forLicenseID: "lic-paid") == nil)
    }

    @Test("trialExpiry is nil when the licenseID is not present in included")
    internal func trialExpiryNilForUnknownID() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payloadWithLicenseID(
                metaExpiry: futureExpiry,
                licenseID: "lic-A",
                licenseExpiry: "2026-07-28T00:00:00.000Z"
            )
        )
        store.save(lease(machineFile: file))
        // "lic-OTHER" is not in the payload → nil.
        #expect(store.trialExpiry(forLicenseID: "lic-OTHER") == nil)
    }

    @Test("trialExpiry is nil when license expiry string is malformed")
    internal func trialExpiryNilForMalformedExpiry() throws {
        let store = makeStore(InMemoryLeaseStorage())
        // Inject a garbage expiry string via a hand-crafted JSON payload.
        let licenseEntry = #"{"type":"licenses","id":"lic-A","attributes":{"expiry":"not-a-date"}}"#
        let payloadBody =
            #"{"meta":{"expiry":"\#(futureExpiry)"},"included":[\#(licenseEntry)]}"#
        let file = try signedMachineFile(payload: payloadBody)
        store.save(lease(machineFile: file))
        #expect(store.trialExpiry(forLicenseID: "lic-A") == nil)
    }

    @Test("trialExpiry is nil when no lease is stored")
    internal func trialExpiryNilWithNoLease() {
        let store = makeStore(InMemoryLeaseStorage())
        #expect(store.trialExpiry(forLicenseID: "lic-A") == nil)
    }

    @Test("clear removes a stored lease")
    internal func clearRemovesLease() throws {
        let storage = InMemoryLeaseStorage()
        let store = makeStore(storage)
        let lease = StowerLicenseLease(
            licenseKey: "K",
            licenseID: "L",
            machineFile: try validMachineFile(),
            validatedAt: Date(timeIntervalSince1970: 1)
        )

        store.save(lease)
        store.clear()

        #expect(store.load() == nil)
    }
}

// MARK: - trialExpiry(forMachineFile:) + plain-ISO parse — Task 8 (I-H12b,d)

extension StowerLicenseLeaseStoreTests {
    @Test("trialExpiry(forMachineFile:) is nil on a bad-signature machine file")
    internal func trialExpiryForMachineFileNilOnBadSignature() throws {
        let store = makeStore(InMemoryLeaseStorage())
        let payloadBody = payloadWithLicenseID(
            metaExpiry: futureExpiry,
            licenseID: "lic-A",
            licenseExpiry: "2026-07-28T00:00:00.000Z"
        )
        let payloadEnc = Data(payloadBody.utf8).base64EncodedString()
        let signature = try signingKey.signature(for: Data(("machine/" + payloadEnc).utf8))
        // The signature covers the real payload, but the file carries a mutated enc,
        // so verifyMachineFile fails before any expiry is read.
        let tampered = machineFile(enc: payloadEnc + "AA", sig: signature.base64EncodedString())
        #expect(store.trialExpiry(forMachineFile: tampered, licenseID: "lic-A") == nil)
    }

    @Test("trialExpiry parses a plain ISO-8601 expiry (no fractional seconds)")
    internal func trialExpiryParsesPlainISO() throws {
        let plainExpiry = "2026-07-28T00:00:00Z"  // no fractional seconds
        let store = makeStore(InMemoryLeaseStorage())
        let file = try signedMachineFile(
            payload: payloadWithLicenseID(
                metaExpiry: futureExpiry,
                licenseID: "lic-A",
                licenseExpiry: plainExpiry
            )
        )
        store.save(lease(machineFile: file))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(store.trialExpiry(forLicenseID: "lic-A") == formatter.date(from: plainExpiry))
    }
}
