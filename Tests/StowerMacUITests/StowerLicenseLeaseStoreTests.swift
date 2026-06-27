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
