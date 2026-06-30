import Foundation
import Testing
import os

@testable import StowerMacUI

/// The install fingerprint hashes its single injected UUID source (I11), has no
/// hardware seam, and resolves that source exactly once per instance so a
/// write-failing Keychain can't rotate the identity mid-process.
@Suite internal struct StowerKeychainFingerprintTests {
    /// The well-known SHA-256 of the ASCII string "abc".
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test("emits SHA-256 hex of the install UUID, never the raw UUID")
    internal func hashesInstallUUID() {
        let fingerprint = StowerKeychainFingerprint(installUUID: { "abc" })

        let output = fingerprint.fingerprint()

        #expect(output == abcDigest)
        #expect(output != "abc")
        #expect(output.count == 64)
    }

    @Test("resolves the install UUID once and caches it across calls")
    internal func resolvesInstallUUIDOnce() {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        // A Keychain whose write keeps failing would hand back a new UUID per call;
        // model that with a counter-backed provider and assert it runs exactly once.
        let fingerprint = StowerKeychainFingerprint(installUUID: {
            callCount.withLock { count in
                count += 1
                return "uuid-\(count)"
            }
        })

        let first = fingerprint.fingerprint()
        let second = fingerprint.fingerprint()

        #expect(first == second)
        #expect(callCount.withLock { $0 } == 1)
        #expect(first == StowerKeychainFingerprint.sha256Hex("uuid-1"))
    }
}
