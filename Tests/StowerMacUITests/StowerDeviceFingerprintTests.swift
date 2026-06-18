import Foundation
import Testing

@testable import StowerMacUI

/// The device fingerprint hashes its UUID (I11) and falls back to the cached UUID
/// when IOKit exposes none — both with injected sources, never touching IOKit or
/// the Keychain.
@Suite internal struct StowerDeviceFingerprintTests {
    /// The well-known SHA-256 of the ASCII string "abc".
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test("emits SHA-256 hex of the hardware UUID, never the raw UUID")
    internal func hashesHardwareUUID() {
        let fingerprint = StowerDeviceFingerprint(
            readHardwareUUID: { "abc" },
            fallbackUUID: { "unused" }
        )

        let output = fingerprint.fingerprint()

        #expect(output == abcDigest)
        #expect(output != "abc")
    }

    @Test("falls back to the cached UUID only when IOKit returns none")
    internal func fallsBackWhenNoHardwareUUID() {
        let fingerprint = StowerDeviceFingerprint(
            readHardwareUUID: { nil },
            fallbackUUID: { "fallback-uuid" }
        )

        let output = fingerprint.fingerprint()

        #expect(output == StowerDeviceFingerprint.sha256Hex("fallback-uuid"))
        #expect(output != "fallback-uuid")
        #expect(output.count == 64)
    }
}
