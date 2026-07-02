import Foundation

#if DEBUG

    /// The parsed DEBUG-only launch-argument levers for exercising the LS
    /// licensing lifecycle in seconds instead of a 7-day manual wait:
    /// `--clear-license` wipes the stored license (forces the trial/paywall
    /// path on next launch) and `--reset-trial` restarts the 7-day trial clock.
    ///
    /// `#if DEBUG`-only: the whole seam (this parser + its gate wiring) is
    /// compile-stripped from a Release archive, so a customer build has no path
    /// to these levers. The parser is pure — the caller supplies
    /// `CommandLine.arguments` — mirroring `StowerLicenseConfig.resolve`, so the
    /// parse matrix is unit-tested deterministically.
    internal struct StowerLicenseDebugArguments: Equatable {
        /// Whether to clear the stored license before the gate runs (forces the
        /// trial/paywall path).
        internal let clearLicense: Bool

        /// Whether to reset the trial clock's first-launch date (restarts the
        /// 7-day window).
        internal let resetTrial: Bool

        /// Parses the launch arguments into the debug levers.
        ///
        /// Unknown arguments (Xcode-/XCTest-injected launch args like
        /// `-NSDocumentRevisionsDebugMode`) are ignored, never block boot.
        internal static func parse(_ arguments: [String]) -> StowerLicenseDebugArguments {
            StowerLicenseDebugArguments(
                clearLicense: arguments.contains(clearLicenseFlag),
                resetTrial: arguments.contains(resetTrialFlag)
            )
        }

        private static let clearLicenseFlag = "--clear-license"
        private static let resetTrialFlag = "--reset-trial"
    }

#endif
