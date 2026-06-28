import CryptoKit
import Foundation
import Testing

@testable import StowerMacUI

/// `StowerLicenseGate.currentStatus` — the reachable-check-in vs. signed-lease-TTL
/// branching (B-I1/I2/I4/I5/I6/I7/I8/I8b/I9/I10).
///
/// Driven by a spy check-in client, an in-memory lease store keyed with a known
/// Ed25519 key, and a fixed fingerprint — no network, no Keychain.
@Suite internal struct StowerLicenseGateTests {
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

    /// A signed machine file whose `enc` carries `expiry` + entitlement `codes`.
    private func machineFile(expiry: String, codes: [String]) throws -> String {
        let entitlements =
            codes
            .map { #"{"type":"entitlements","attributes":{"code":"\#($0)"}}"# }
            .joined(separator: ",")
        let payload = #"{"meta":{"expiry":"\#(expiry)"},"included":[\#(entitlements)]}"#
        let enc = Data(payload.utf8).base64EncodedString()
        let signature = try signingKey.signature(for: Data(("machine/" + enc).utf8))
        let json =
            #"{"enc":"\#(enc)","sig":"\#(signature.base64EncodedString())","alg":"base64+ed25519"}"#
        let body = Data(json.utf8).base64EncodedString()
        return "-----BEGIN MACHINE FILE-----\n\(body)\n-----END MACHINE FILE-----"
    }

    private func lease(key: String, id: String, file: String) -> StowerLicenseLease {
        StowerLicenseLease(licenseKey: key, licenseID: id, machineFile: file, validatedAt: now)
    }

    @Test("B-I2: first run with no lease mints, stores the lease, and is valid")
    internal func firstRunMintsAndStores() async throws {
        let file = try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
        let client = SpyCheckInClient(
            mint: [.minted(licenseKey: "KEY", licenseID: "lic-1", machineFile: file)]
        )
        let store = makeStore()
        let gate = makeGate(client: client, store: store)

        #expect(await gate.currentStatus(now: now) == .valid)
        let stored = try #require(store.load())
        #expect(stored == lease(key: "KEY", id: "lic-1", file: file))
        let authority = try #require(store.offlineAuthority(now: now))
        #expect(authority.entitlementCodes == ["STOWER_TRIAL"])
        #expect(client.mintFingerprints == [expectedFingerprint])
    }

    @Test("B-I1: a warm reachable lease check-ins and stores the fresh signed file")
    internal func warmLeaseChecksInAndStoresFreshFile() async throws {
        let staleFile = try machineFile(expiry: futureExpiry, codes: ["STOWER_V0"])
        let freshFile = try machineFile(expiry: futureExpiry, codes: ["STOWER_V0"])
        let store = makeStore()
        store.save(lease(key: "KEY", id: "lic-1", file: staleFile))
        let client = SpyCheckInClient(checkIn: [.ok(machineFile: freshFile)])
        let gate = makeGate(client: client, store: store)

        let later = now.addingTimeInterval(60)
        #expect(await gate.currentStatus(now: later) == .valid)
        let stored = try #require(store.load())
        #expect(stored.machineFile == freshFile)
        #expect(stored.validatedAt == later)
        #expect(
            client.checkInCalls == [
                .init(licenseID: "lic-1", fingerprint: expectedFingerprint, licenseKey: "KEY")
            ]
        )
    }

    @Test("B-I4: a check-in expired verdict maps to .trialExpired")
    internal func expiredMapsToTrialExpired() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let client = SpyCheckInClient(checkIn: [.trialExpired(licenseID: "lic-1")])
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .trialExpired(licenseID: "lic-1"))
    }

    @Test("B-I7: a check-in wrong_version verdict maps to .wrongVersion")
    internal func wrongVersionMaps() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let client = SpyCheckInClient(checkIn: [.wrongVersion(licenseID: "lic-1")])
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .wrongVersion(licenseID: "lic-1"))
    }

    @Test(
        "B-I5: unreachable + a valid signed file before its TTL is valid; past TTL is couldNotReach"
    )
    internal func offlineValidBeforeTTLBlockedAfter() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let client = SpyCheckInClient(checkIn: [.unreachable, .unreachable])
        let gate = makeGate(client: client, store: store)
        // Before the file's expiry → offline-valid.
        #expect(await gate.currentStatus(now: now) == .valid)

        // After the file's expiry (use a now past 2030) → no offline authority.
        let pastTTL = Date(timeIntervalSince1970: 2_000_000_000)  // 2033
        #expect(await gate.currentStatus(now: pastTTL) == .couldNotReach)
    }

    @Test("B-I6: unreachable + a signed file lacking STOWER_TRIAL/STOWER_V0 is couldNotReach")
    internal func offlineRejectsWrongEntitlement() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_LEGACY"])
            )
        )
        let client = SpyCheckInClient(checkIn: [.unreachable])
        let gate = makeGate(client: client, store: store)
        #expect(await gate.currentStatus(now: now) == .couldNotReach)
    }

    @Test("B-I8: no lease + mint unreachable is .needsTrialOnline")
    internal func firstRunOfflineNeedsTrialOnline() async {
        let client = SpyCheckInClient(mint: [.unreachable])
        let gate = makeGate(client: client, store: makeStore())
        #expect(await gate.currentStatus(now: now) == .needsTrialOnline)
    }

    @Test("B-I8: mint retryShortly is .couldNotReach (distinct from offline-first-run)")
    internal func mintRetryShortlyIsCouldNotReach() async {
        let client = SpyCheckInClient(mint: [.retryShortly])
        let gate = makeGate(client: client, store: makeStore())
        #expect(await gate.currentStatus(now: now) == .couldNotReach)
    }

    @Test("B-I8b (JC6): unknown_license clears the stale lease and re-mints, never loops")
    internal func unknownLicenseSelfHeals() async throws {
        let oldFile = try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
        let newFile = try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
        let store = makeStore()
        store.save(lease(key: "OLD", id: "lic-old", file: oldFile))
        let client = SpyCheckInClient(
            mint: [.minted(licenseKey: "NEW", licenseID: "lic-new", machineFile: newFile)],
            checkIn: [.unknownLicense]
        )
        let gate = makeGate(client: client, store: store)

        #expect(await gate.currentStatus(now: now) == .valid)
        // The stale lease was cleared and replaced by the freshly minted one.
        let stored = try #require(store.load())
        #expect(stored.licenseID == "lic-new")
        #expect(client.mintFingerprints == [expectedFingerprint])
    }

    @Test(
        "B-I8b (JC6): unknown_license then an unreachable mint clears the lease and connects-once"
    )
    internal func unknownLicenseThenOfflineConnectsOnce() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "OLD",
                id: "lic-old",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let client = SpyCheckInClient(mint: [.unreachable], checkIn: [.unknownLicense])
        let gate = makeGate(client: client, store: store)

        #expect(await gate.currentStatus(now: now) == .needsTrialOnline)
        // The stale lease is gone, so hasLease() is false and a retry mints rather
        // than re-404ing.
        #expect(store.load() == nil)
        #expect(!gate.hasLease())
    }

    @Test("B-I9: the gate signs every check-in with the stored key, never one round-tripped")
    internal func signsWithStoredKeyEachCall() async throws {
        let file = try machineFile(expiry: futureExpiry, codes: ["STOWER_V0"])
        let store = makeStore()
        store.save(lease(key: "SECRET", id: "lic-1", file: file))
        // Check-in returns a fresh file (and never a key); the next call must still
        // sign with the stored "SECRET".
        let client = SpyCheckInClient(checkIn: [.ok(machineFile: file), .ok(machineFile: file)])
        let gate = makeGate(client: client, store: store)

        _ = await gate.currentStatus(now: now)
        _ = await gate.currentStatus(now: now)
        #expect(client.checkInCalls.allSatisfy { $0.licenseKey == "SECRET" })
        #expect(client.checkInCalls.count == 2)
    }

    @Test("B-I10: only the SHA-256 fingerprint hash is sent, never the raw uuid")
    internal func sendsHashedFingerprint() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let client = SpyCheckInClient(checkIn: [
            .ok(machineFile: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"]))
        ])
        let gate = makeGate(client: client, store: store)

        _ = await gate.currentStatus(now: now)
        let sent = try #require(client.checkInCalls.first)
        #expect(sent.fingerprint == expectedFingerprint)
        #expect(sent.fingerprint != knownUUID)
    }
}

// MARK: - trialBadge() tests

extension StowerLicenseGateTests {
    /// A signed machine file whose `enc` payload includes the given license entry
    /// (with `id` and optional `expiry`) alongside the given entitlement codes.
    private func machineFileWithLicense(
        metaExpiry: String,
        licenseID: String,
        licenseExpiry: String?,
        codes: [String]
    ) throws -> String {
        let entitlements =
            codes
            .map { #"{"type":"entitlements","attributes":{"code":"\#($0)"}}"# }
            .joined(separator: ",")
        let licenseEntry: String
        if let exp = licenseExpiry {
            licenseEntry =
                #"{"type":"licenses","id":"\#(licenseID)","attributes":{"expiry":"\#(exp)"}}"#
        } else {
            licenseEntry =
                #"{"type":"licenses","id":"\#(licenseID)","attributes":{"expiry":null}}"#
        }
        let allIncluded = [entitlements, licenseEntry].filter { !$0.isEmpty }.joined(separator: ",")
        let payload = #"{"meta":{"expiry":"\#(metaExpiry)"},"included":[\#(allIncluded)]}"#
        let enc = Data(payload.utf8).base64EncodedString()
        let signature = try signingKey.signature(for: Data(("machine/" + enc).utf8))
        let json =
            #"{"enc":"\#(enc)","sig":"\#(signature.base64EncodedString())","alg":"base64+ed25519"}"#
        let body = Data(json.utf8).base64EncodedString()
        return "-----BEGIN MACHINE FILE-----\n\(body)\n-----END MACHINE FILE-----"
    }

    @Test("trialBadge returns badge with id-matched license expiry for an active trial")
    internal func trialBadgeReturnsBadgeOnActiveTrial() async throws {
        let licenseExpiry = "2026-07-28T00:00:00.000Z"
        let file = try machineFileWithLicense(
            metaExpiry: futureExpiry,
            licenseID: "lic-trial",
            licenseExpiry: licenseExpiry,
            codes: ["STOWER_TRIAL"]
        )
        let store = makeStore()
        store.save(lease(key: "KEY", id: "lic-trial", file: file))
        let gate = makeGate(client: SpyCheckInClient(), store: store)

        let badge = try #require(gate.trialBadge())
        #expect(badge.licenseID == "lic-trial")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(badge.expiry == formatter.date(from: licenseExpiry))
    }

    @Test("trialBadge is nil when the license expiry is null (paid/perpetual)")
    internal func trialBadgeNilForPaidLicense() async throws {
        let file = try machineFileWithLicense(
            metaExpiry: futureExpiry,
            licenseID: "lic-paid",
            licenseExpiry: nil,
            codes: ["STOWER_V0"]
        )
        let store = makeStore()
        store.save(lease(key: "KEY", id: "lic-paid", file: file))
        let gate = makeGate(client: SpyCheckInClient(), store: store)

        #expect(gate.trialBadge() == nil)
    }

    @Test("trialBadge is nil when no lease is stored")
    internal func trialBadgeNilWithNoLease() {
        let gate = makeGate(client: SpyCheckInClient(), store: makeStore())
        #expect(gate.trialBadge() == nil)
    }
}
