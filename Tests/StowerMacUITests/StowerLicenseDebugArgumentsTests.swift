import Foundation
import Testing

@testable import StowerMacUI

#if DEBUG

    /// The DEBUG-only launch-arg parser's parse matrix, value mapping, and hashed
    /// fingerprint invariant.
    ///
    /// Pure — the argument array is passed in, so every case is asserted with no
    /// `CommandLine` read, mirroring `StowerLicenseConfigTests`' pure-resolver shape.
    @Suite internal struct StowerLicenseDebugArgumentsTests {
        private let fingerprintFlag = "--fingerprint"

        private func success(
            clearLeaseOnStart: Bool = false,
            fingerprintOverride: String? = nil
        ) -> Result<StowerLicenseDebugArguments, StowerLicenseDebugArguments.ParseError> {
            .success(
                StowerLicenseDebugArguments(
                    clearLeaseOnStart: clearLeaseOnStart,
                    fingerprintOverride: fingerprintOverride
                )
            )
        }

        @Test("no debug args ⇒ both levers off")
        internal func noArgs() {
            #expect(StowerLicenseDebugArguments.parse([]) == success())
        }

        @Test("--clear-lease-on-start alone sets only the clear lever")
        internal func clearFlagOnly() {
            #expect(
                StowerLicenseDebugArguments.parse(["--clear-lease-on-start"])
                    == success(clearLeaseOnStart: true)
            )
        }

        @Test("I-H7: --fingerprint with a value maps to that override")
        internal func fingerprintWithValue() {
            #expect(
                StowerLicenseDebugArguments.parse(["--fingerprint", "dev-1"])
                    == success(fingerprintOverride: "dev-1")
            )
        }

        @Test("both flags compose")
        internal func bothFlags() {
            #expect(
                StowerLicenseDebugArguments.parse(
                    ["--clear-lease-on-start", "--fingerprint", "dev-1"]
                ) == success(clearLeaseOnStart: true, fingerprintOverride: "dev-1")
            )
        }

        @Test("I-H7: a dangling --fingerprint refuses with a named reason")
        internal func danglingFingerprint() {
            #expect(
                StowerLicenseDebugArguments.parse(["--fingerprint"])
                    == .failure(.missingValue(flag: fingerprintFlag))
            )
        }

        @Test("I-H7: --fingerprint followed by another flag does not eat the flag")
        internal func fingerprintEatsNoFlag() {
            #expect(
                StowerLicenseDebugArguments.parse(["--fingerprint", "--clear-lease-on-start"])
                    == .failure(.missingValue(flag: fingerprintFlag))
            )
        }

        @Test("I-H7: an empty / whitespace --fingerprint value refuses")
        internal func fingerprintEmptyOrWhitespace() {
            // Never SHA-256("") — an empty/whitespace value collides across runs.
            #expect(
                StowerLicenseDebugArguments.parse(["--fingerprint", ""])
                    == .failure(.missingValue(flag: fingerprintFlag))
            )
            #expect(
                StowerLicenseDebugArguments.parse(["--fingerprint", "   "])
                    == .failure(.missingValue(flag: fingerprintFlag))
            )
        }

        @Test("I-H7: a duplicate --fingerprint refuses, never silently takes the first")
        internal func duplicateFingerprint() {
            #expect(
                StowerLicenseDebugArguments.parse(
                    ["--fingerprint", "dev-1", "--fingerprint", "dev-2"]
                ) == .failure(.missingValue(flag: fingerprintFlag))
            )
        }

        @Test("I-H7: an unknown arg is ignored (Xcode/XCTest args don't block boot)")
        internal func unknownArgIgnored() {
            #expect(
                StowerLicenseDebugArguments.parse(["-NSDocumentRevisionsDebugMode", "YES"])
                    == success()
            )
        }

        @Test("I-H6: the pinned --fingerprint value is hashed before the wire, never sent raw")
        internal func fingerprintIsHashed() throws {
            let parsed = try StowerLicenseDebugArguments.parse(
                ["--fingerprint", "dev-1"]
            ).get()
            #expect(parsed.fingerprintOverride == "dev-1")

            let fingerprint = StowerDeviceFingerprint(
                readHardwareUUID: { "dev-1" },
                fallbackUUID: { "dev-1" }
            )
            let sent = fingerprint.fingerprint()
            #expect(sent == StowerDeviceFingerprint.sha256Hex("dev-1"))
            #expect(sent != "dev-1")
        }
    }

#endif
