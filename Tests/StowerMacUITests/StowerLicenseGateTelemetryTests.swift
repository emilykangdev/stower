import CryptoKit
import Foundation
import Testing

@testable import StowerMacUI

/// `StowerLicenseGate` emits exactly one `licenseUnreachable` analytics signal on
/// each genuine-unreachable / local-failure resolution, carrying the coarse
/// PII-safe reason + endpoint — and NONE on a reachable-but-rejected verdict
/// (401/409) or a `.valid` (JC1).
///
/// Driven by a spy check-in client, an in-memory lease store keyed with a known
/// Ed25519 key, a fixed fingerprint, and a `StowerInMemoryAnalyticsReporter` spy.
@Suite internal struct StowerLicenseGateTelemetryTests {
    private let signingKey = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let futureExpiry = "2030-01-01T00:00:00.000Z"
    private let knownUUID = "AAAA-BBBB-CCCC-DDDD"

    private var publicKeyHex: String {
        signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    private func makeStore() -> StowerLicenseLeaseStore {
        StowerLicenseLeaseStore(storage: StowerInMemoryLeaseStorage(), publicKeyHex: publicKeyHex)
    }

    private func makeGate(
        client: SpyCheckInClient,
        store: StowerLicenseLeaseStore,
        reporter: any StowerAnalyticsReporting
    ) -> StowerLicenseGate {
        StowerLicenseGate(
            client: client,
            leaseStore: store,
            fingerprint: StowerKeychainFingerprint(installUUID: { self.knownUUID }),
            reporter: reporter
        )
    }

    /// A signed machine file whose `enc` carries `expiry` + entitlement `codes`
    /// (no `data` block, so the device match fails open).
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

    /// One reported `licenseUnreachable` payload, extracted from the spy reporter.
    private struct UnreachableSignal: Equatable {
        let reason: StowerLicenseUnreachableReason
        let endpoint: StowerLicenseEndpoint
    }

    /// The `licenseUnreachable` events the reporter recorded, in order — every
    /// other event kind is dropped, so the assertions speak only to this signal.
    private func unreachableSignals(
        _ reporter: StowerInMemoryAnalyticsReporter
    ) -> [UnreachableSignal] {
        reporter.recorded().compactMap { event in
            if case .licenseUnreachable(let reason, let endpoint) = event {
                return UnreachableSignal(reason: reason, endpoint: endpoint)
            }
            return nil
        }
    }

    @Test("mint unreachable reports exactly one licenseUnreachable(.transport, .mintTrial)")
    internal func mintUnreachableReportsOnce() async {
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(mint: [.unreachable(.transport)])
        let gate = makeGate(client: client, store: makeStore(), reporter: reporter)

        #expect(await gate.currentStatus(now: now) == .needsTrialOnline)
        #expect(
            unreachableSignals(reporter)
                == [.init(reason: .transport, endpoint: .mintTrial)]
        )
    }

    @Test("mint httpStatus reason flows through to the report")
    internal func mintHTTPStatusReports() async {
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(mint: [.unreachable(.httpStatus(500))])
        let gate = makeGate(client: client, store: makeStore(), reporter: reporter)

        _ = await gate.currentStatus(now: now)
        #expect(
            unreachableSignals(reporter)
                == [.init(reason: .httpStatus(500), endpoint: .mintTrial)]
        )
    }

    @Test("check-in unreachable with no offline authority reports once for .checkIn")
    internal func checkInUnreachableReportsOnce() async throws {
        let store = makeStore()
        // A file lacking STOWER_TRIAL/STOWER_V0 → no offline authority → couldNotReach.
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_LEGACY"])
            )
        )
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(checkIn: [.unreachable(.decodeFailure)])
        let gate = makeGate(client: client, store: store, reporter: reporter)

        #expect(await gate.currentStatus(now: now) == .couldNotReach)
        #expect(
            unreachableSignals(reporter)
                == [.init(reason: .decodeFailure, endpoint: .checkIn)]
        )
    }

    @Test("check-in unreachable but offline-valid reports NOTHING (it resolved to .valid)")
    internal func offlineValidReportsNothing() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(checkIn: [.unreachable(.transport)])
        let gate = makeGate(client: client, store: store, reporter: reporter)

        #expect(await gate.currentStatus(now: now) == .valid)
        #expect(unreachableSignals(reporter).isEmpty)
    }

    @Test("JC1: 401 badSignature reports NO licenseUnreachable (reachable-but-rejected)")
    internal func badSignatureReportsNothing() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(checkIn: [.badSignature])
        let gate = makeGate(client: client, store: store, reporter: reporter)

        #expect(await gate.currentStatus(now: now) == .couldNotReach)
        #expect(unreachableSignals(reporter).isEmpty)
    }

    @Test("JC1: 409 fingerprintMismatch reports NO licenseUnreachable")
    internal func fingerprintMismatchReportsNothing() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
            )
        )
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(checkIn: [.fingerprintMismatch])
        let gate = makeGate(client: client, store: store, reporter: reporter)

        #expect(await gate.currentStatus(now: now) == .couldNotReach)
        #expect(unreachableSignals(reporter).isEmpty)
    }

    @Test("a healthy check-in (.valid) reports no licenseUnreachable")
    internal func validReportsNothing() async throws {
        let store = makeStore()
        store.save(
            lease(
                key: "KEY",
                id: "lic-1",
                file: try machineFile(expiry: futureExpiry, codes: ["STOWER_V0"])
            )
        )
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(checkIn: [
            .ok(machineFile: try machineFile(expiry: futureExpiry, codes: ["STOWER_V0"]))
        ])
        let gate = makeGate(client: client, store: store, reporter: reporter)

        #expect(await gate.currentStatus(now: now) == .valid)
        #expect(unreachableSignals(reporter).isEmpty)
    }

    @Test("a mint that authorizes and stores (.valid) reports no licenseUnreachable")
    internal func mintValidReportsNothing() async throws {
        let file = try machineFile(expiry: futureExpiry, codes: ["STOWER_TRIAL"])
        let reporter = StowerInMemoryAnalyticsReporter()
        let client = SpyCheckInClient(
            mint: [.minted(licenseKey: "KEY", licenseID: "lic-1", machineFile: file)]
        )
        let gate = makeGate(client: client, store: makeStore(), reporter: reporter)

        #expect(await gate.currentStatus(now: now) == .valid)
        #expect(unreachableSignals(reporter).isEmpty)
    }
}
