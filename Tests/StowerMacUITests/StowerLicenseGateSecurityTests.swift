import CryptoKit
import Foundation
import Testing

@testable import StowerMacUI

/// `StowerLicenseGate` security-hardening behaviors, split out of
/// `StowerLicenseGateTests` for file-length.
///
/// Covers the mint-reply expiry gate (a reused expired trial must not re-enter),
/// the failed-Keychain-write guard (never a `.valid` the app cannot persist), and
/// the offline device binding (a signed file copied from another Mac must not grant
/// offline access). Shares the `SpyCheckInClient` / `FailingWriteLeaseStorage`
/// doubles in `Support/`.
@Suite internal struct StowerLicenseGateSecurityTests {
    private let signingKey = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let futureExpiry = "2030-01-01T00:00:00.000Z"
    private let pastExpiry = "2020-01-01T00:00:00.000Z"
    private let knownUUID = "AAAA-BBBB-CCCC-DDDD"

    /// The SHA-256 hash the fixed fingerprint produces — what mint/check-in receive.
    private var expectedFingerprint: String {
        StowerDeviceFingerprint.sha256Hex(knownUUID)
    }

    private var publicKeyHex: String {
        signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    private func makeStore() -> StowerLicenseLeaseStore {
        StowerLicenseLeaseStore(storage: StowerInMemoryLeaseStorage(), publicKeyHex: publicKeyHex)
    }

    private func makeGate(
        client: SpyCheckInClient,
        store: StowerLicenseLeaseStore
    ) -> StowerLicenseGate {
        StowerLicenseGate(
            client: client,
            leaseStore: store,
            fingerprint: StowerDeviceFingerprint(
                readHardwareUUID: { self.knownUUID },
                fallbackUUID: { self.knownUUID }
            )
        )
    }

    private func lease(key: String, id: String, file: String) -> StowerLicenseLease {
        StowerLicenseLease(licenseKey: key, licenseID: id, machineFile: file, validatedAt: now)
    }

    /// Wraps a `{data?, meta, included}` body as a correctly-signed machine file.
    private func signedFile(payload: String) throws -> String {
        let enc = Data(payload.utf8).base64EncodedString()
        let signature = try signingKey.signature(for: Data(("machine/" + enc).utf8))
        let json =
            #"{"enc":"\#(enc)","sig":"\#(signature.base64EncodedString())","alg":"base64+ed25519"}"#
        let body = Data(json.utf8).base64EncodedString()
        return "-----BEGIN MACHINE FILE-----\n\(body)\n-----END MACHINE FILE-----"
    }

    /// A signed machine file carrying the checked-out device
    /// `data.attributes.fingerprint` alongside `expiry` + entitlement `codes`.
    private func machineFile(
        expiry: String,
        codes: [String],
        fingerprint: String
    ) throws -> String {
        let entitlements =
            codes
            .map { #"{"type":"entitlements","attributes":{"code":"\#($0)"}}"# }
            .joined(separator: ",")
        let payload =
            #"{"data":{"attributes":{"fingerprint":"\#(fingerprint)"}},"#
            + #""meta":{"expiry":"\#(expiry)"},"included":[\#(entitlements)]}"#
        return try signedFile(payload: payload)
    }

    /// A signed machine file with no `data` block (so no device fingerprint).
    private func machineFile(expiry: String, codes: [String]) throws -> String {
        let entitlements =
            codes
            .map { #"{"type":"entitlements","attributes":{"code":"\#($0)"}}"# }
            .joined(separator: ",")
        let payload = #"{"meta":{"expiry":"\#(expiry)"},"included":[\#(entitlements)]}"#
        return try signedFile(payload: payload)
    }

    /// A signed machine file with an `id`-matched license entry whose expiry is
    /// `licenseExpiry` (the trial-state field the mint gate reads).
    private func machineFileWithLicense(
        licenseID: String,
        licenseExpiry: String,
        codes: [String]
    ) throws -> String {
        let entitlements =
            codes
            .map { #"{"type":"entitlements","attributes":{"code":"\#($0)"}}"# }
            .joined(separator: ",")
        let license =
            #"{"type":"licenses","id":"\#(licenseID)","attributes":{"expiry":"\#(licenseExpiry)"}}"#
        let payload =
            #"{"meta":{"expiry":"\#(futureExpiry)"},"included":[\#(entitlements),\#(license)]}"#
        return try signedFile(payload: payload)
    }

    @Test("mint reusing an already-expired trial routes to .trialExpired, never .valid")
    internal func mintExpiredReusedTrialIsTrialExpired() async throws {
        // The Edge Function reuses an existing trial row for a known fingerprint and
        // returns a signed file even when that trial has expired. The gate must not
        // blind-trust `.minted`: a past signed license expiry routes to the paywall.
        let file = try machineFileWithLicense(
            licenseID: "lic-exp",
            licenseExpiry: pastExpiry,
            codes: ["STOWER_TRIAL"]
        )
        let client = SpyCheckInClient(
            mint: [.minted(licenseKey: "K", licenseID: "lic-exp", machineFile: file)]
        )
        let gate = makeGate(client: client, store: makeStore())
        #expect(await gate.currentStatus(now: now) == .trialExpired(licenseID: "lic-exp"))
    }

    @Test("mint reusing a still-active trial (future signed license expiry) is valid")
    internal func mintActiveReusedTrialIsValid() async throws {
        let file = try machineFileWithLicense(
            licenseID: "lic-act",
            licenseExpiry: futureExpiry,
            codes: ["STOWER_TRIAL"]
        )
        let client = SpyCheckInClient(
            mint: [.minted(licenseKey: "K", licenseID: "lic-act", machineFile: file)]
        )
        let gate = makeGate(client: client, store: makeStore())
        #expect(await gate.currentStatus(now: now) == .valid)
    }

    @Test("check-in ok but a failed Keychain write yields .couldNotReach, not an unhonored .valid")
    internal func checkInOkSaveFailureIsCouldNotReach() async throws {
        let file = try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
        let seeded = try JSONEncoder().encode(lease(key: "KEY", id: "lic-1", file: file))
        let store = StowerLicenseLeaseStore(
            storage: FailingWriteLeaseStorage(seeded: seeded),
            publicKeyHex: publicKeyHex
        )
        let client = SpyCheckInClient(checkIn: [.ok(machineFile: file)])
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .couldNotReach)
    }

    @Test("mint ok but a failed Keychain write yields .couldNotReach")
    internal func mintSaveFailureIsCouldNotReach() async throws {
        let file = try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
        let store = StowerLicenseLeaseStore(
            storage: FailingWriteLeaseStorage(),
            publicKeyHex: publicKeyHex
        )
        let client = SpyCheckInClient(
            mint: [.minted(licenseKey: "K", licenseID: "lic-1", machineFile: file)]
        )
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .couldNotReach)
    }

    @Test("offline rejects a signed file checked out for a different device (no trial sharing)")
    internal func offlineRejectsForeignDeviceFile() async throws {
        let foreign = try machineFile(
            expiry: futureExpiry,
            codes: ["STOWER_TRIAL"],
            fingerprint: "A-DIFFERENT-MACS-FINGERPRINT"
        )
        let store = makeStore()
        store.save(lease(key: "KEY", id: "lic-1", file: foreign))
        let client = SpyCheckInClient(checkIn: [.unreachable])
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .couldNotReach)
    }

    @Test("offline accepts a signed file checked out for THIS device")
    internal func offlineAcceptsOwnDeviceFile() async throws {
        let own = try machineFile(
            expiry: futureExpiry,
            codes: ["STOWER_TRIAL"],
            fingerprint: expectedFingerprint
        )
        let store = makeStore()
        store.save(lease(key: "KEY", id: "lic-1", file: own))
        let client = SpyCheckInClient(checkIn: [.unreachable])
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .valid)
    }

    @Test("an online trial-expired verdict clears the lease so going offline cannot re-enter")
    internal func trialExpiredClearsLeaseSoOfflineCannotReenter() async throws {
        // The cached machine file's TTL is still in the future, but the trial expired
        // server-side. Once the paywall is seen online, the file must not re-grant
        // access simply by disconnecting.
        let file = try machineFile(
            expiry: futureExpiry,
            codes: ["STOWER_TRIAL"],
            fingerprint: expectedFingerprint
        )
        let store = makeStore()
        store.save(lease(key: "KEY", id: "lic-1", file: file))
        let client = SpyCheckInClient(checkIn: [.trialExpired(licenseID: "lic-1"), .unreachable])
        let gate = makeGate(client: client, store: store)

        #expect(await gate.currentStatus(now: now) == .trialExpired(licenseID: "lic-1"))
        #expect(store.load() == nil)
        #expect(!gate.hasLease())
        // Now offline with no lease: the mint path is unreachable → connect-once, not
        // a TTL-fallback .valid on the stale file.
        #expect(await gate.currentStatus(now: now) == .needsTrialOnline)
    }

    @Test("mint of an expired reused trial leaves no cached lease for offline re-entry")
    internal func mintExpiredReusedTrialLeavesNoCachedLease() async throws {
        let file = try machineFileWithLicense(
            licenseID: "lic-exp",
            licenseExpiry: pastExpiry,
            codes: ["STOWER_TRIAL"]
        )
        let client = SpyCheckInClient(
            mint: [.minted(licenseKey: "K", licenseID: "lic-exp", machineFile: file)]
        )
        let store = makeStore()
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .trialExpired(licenseID: "lic-exp"))
        #expect(store.load() == nil)
    }

    @Test("check-in ok with a file that does not authorize this build is couldNotReach")
    internal func checkInOkUnauthorizedFileIsCouldNotReach() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        // The server replies ok but with a file lacking STOWER_TRIAL/STOWER_V0; the
        // gate must verify the stored file authorizes this build before .valid.
        let badFile = try machineFile(expiry: futureExpiry, codes: ["STOWER_LEGACY"])
        let client = SpyCheckInClient(checkIn: [.ok(machineFile: badFile)])
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .couldNotReach)
    }
}
