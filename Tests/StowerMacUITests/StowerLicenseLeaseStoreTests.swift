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

/// An in-memory `StowerLeaseStorage` so the lease tests touch neither the
/// Keychain nor disk.
private final class InMemoryLeaseStorage: StowerLeaseStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?

    func readData() -> Data? {
        lock.withLock { blob }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.withLock { blob = data }
        return true
    }

    func delete() {
        lock.withLock { blob = nil }
    }
}
