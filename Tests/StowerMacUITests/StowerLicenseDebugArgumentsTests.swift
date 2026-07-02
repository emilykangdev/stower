import Foundation
import Testing

@testable import StowerMacUI

#if DEBUG

    /// The DEBUG-only launch-arg parser's parse matrix.
    ///
    /// Pure — the argument array is passed in, so every case is asserted with no
    /// `CommandLine` read, mirroring `StowerLicenseConfigTests`' pure-resolver shape.
    @Suite internal struct StowerLicenseDebugArgumentsTests {
        @Test("no debug args ⇒ both levers off")
        internal func noArgs() {
            let parsed = StowerLicenseDebugArguments.parse([])
            #expect(!parsed.clearLicense)
            #expect(!parsed.resetTrial)
        }

        @Test("--clear-license alone sets only the clear-license lever")
        internal func clearLicenseOnly() {
            let parsed = StowerLicenseDebugArguments.parse(["--clear-license"])
            #expect(parsed.clearLicense)
            #expect(!parsed.resetTrial)
        }

        @Test("--reset-trial alone sets only the reset-trial lever")
        internal func resetTrialOnly() {
            let parsed = StowerLicenseDebugArguments.parse(["--reset-trial"])
            #expect(!parsed.clearLicense)
            #expect(parsed.resetTrial)
        }

        @Test("both flags compose")
        internal func bothFlags() {
            let parsed = StowerLicenseDebugArguments.parse(["--clear-license", "--reset-trial"])
            #expect(parsed.clearLicense)
            #expect(parsed.resetTrial)
        }

        @Test("an unknown arg is ignored (Xcode/XCTest args don't block boot)")
        internal func unknownArgIgnored() {
            let parsed = StowerLicenseDebugArguments.parse(["-NSDocumentRevisionsDebugMode", "YES"])
            #expect(!parsed.clearLicense)
            #expect(!parsed.resetTrial)
        }
    }

#endif
