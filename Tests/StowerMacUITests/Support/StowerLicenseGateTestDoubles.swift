import Foundation

@testable import StowerMacUI

/// A scripted `StowerLicenseCheckInProviding` spy recording the fingerprint sent
/// to mint and the full `(licenseID, fingerprint, licenseKey)` of each check-in.
///
/// Shared across the gate suites (`StowerLicenseGateTests` and
/// `StowerLicenseGateSecurityTests`); each scripted result list is replayed in
/// order, repeating the last entry once exhausted.
internal final class SpyCheckInClient: StowerLicenseCheckInProviding, @unchecked Sendable {
    /// One recorded check-in call's arguments.
    internal struct CheckInCall: Equatable {
        internal let licenseID: String
        internal let fingerprint: String
        internal let licenseKey: String
    }

    private let lock = NSLock()
    private let mintResults: [StowerTrialMint]
    private let checkInResults: [StowerCheckInResult]
    private var mintIndex = 0
    private var checkInIndex = 0
    private var recordedMintFingerprints: [String] = []
    private var recordedCheckInCalls: [CheckInCall] = []

    internal init(mint: [StowerTrialMint] = [], checkIn: [StowerCheckInResult] = []) {
        self.mintResults = mint
        self.checkInResults = checkIn
    }

    internal var mintFingerprints: [String] {
        lock.withLock { recordedMintFingerprints }
    }

    internal var checkInCalls: [CheckInCall] {
        lock.withLock { recordedCheckInCalls }
    }

    internal func mint(fingerprint: String) async -> StowerTrialMint {
        lock.withLock {
            recordedMintFingerprints.append(fingerprint)
            guard !mintResults.isEmpty else { return .unreachable(.transport) }
            let index = min(mintIndex, mintResults.count - 1)
            mintIndex += 1
            return mintResults[index]
        }
    }

    internal func checkIn(
        licenseID: String,
        fingerprint: String,
        licenseKey: String
    ) async -> StowerCheckInResult {
        lock.withLock {
            recordedCheckInCalls.append(
                CheckInCall(licenseID: licenseID, fingerprint: fingerprint, licenseKey: licenseKey)
            )
            guard !checkInResults.isEmpty else { return .unreachable(.transport) }
            let index = min(checkInIndex, checkInResults.count - 1)
            checkInIndex += 1
            return checkInResults[index]
        }
    }
}

/// A `StowerLeaseStorage` that reads a pre-seeded blob but whose `write` always
/// fails — so the gate's save-failure branch (a failed Keychain write must not
/// report `.valid`) is exercised deterministically.
internal final class FailingWriteLeaseStorage: StowerLeaseStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?

    internal init(seeded: Data? = nil) {
        self.blob = seeded
    }

    internal func readData() -> Data? {
        lock.withLock { blob }
    }

    internal func write(_ data: Data) -> Bool {
        false
    }

    internal func delete() {
        lock.withLock { blob = nil }
    }
}
