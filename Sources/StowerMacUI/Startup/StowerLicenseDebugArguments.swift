import Foundation

#if DEBUG

    /// The parsed DEBUG-only launch-argument levers that drive the licensing
    /// lifecycle in seconds instead of a 30-day manual slog: `--clear-lease-on-start`
    /// forces a fresh mint on next launch, and `--fingerprint <value>` pins device
    /// identity to `SHA-256(<value>)` so a trial survives relaunch (to observe
    /// expiry) or a bumped value mints a fresh one.
    ///
    /// `#if DEBUG`-only: the whole seam (this parser + its gate wiring) is
    /// compile-stripped from a Release archive, so a customer build has no path to
    /// these levers. The parser is pure — the caller supplies `CommandLine.arguments`
    /// — mirroring `StowerLicenseConfig.resolve`, so the parse matrix is unit-tested
    /// deterministically.
    ///
    /// See `Docs/license-smoke.md` for how these args reach the app and the manual
    /// expiry/payment smoke runbook.
    internal struct StowerLicenseDebugArguments: Equatable {
        /// Whether to clear the stored lease before the gate runs (forces a mint).
        internal let clearLeaseOnStart: Bool

        /// The raw `--fingerprint` value to pin device identity to (hashed before
        /// it leaves the device), or `nil` when the flag was absent.
        internal let fingerprintOverride: String?

        /// A *recognized* flag given malformed input — the flag name is non-secret.
        internal enum ParseError: Error, Equatable {
            /// A recognized flag (e.g. `--fingerprint`) given no/malformed value, or
            /// passed more than once.
            case missingValue(flag: String)
        }

        /// Parses the launch arguments into the debug levers.
        ///
        /// A malformed *recognized* flag — `--fingerprint` with no value, a following
        /// `--…` token, an empty/whitespace value, or a duplicate `--fingerprint` —
        /// returns `.failure(.missingValue("--fingerprint"))` so the caller can refuse
        /// startup with a named reason rather than silently pin the wrong identity. An
        /// *unknown* argument is ignored (never a failure), so Xcode-/XCTest-injected
        /// launch args (`-NSDocumentRevisionsDebugMode`, `-XCTest…`) cannot block boot.
        internal static func parse(
            _ arguments: [String]
        ) -> Result<StowerLicenseDebugArguments, ParseError> {
            let clearLeaseOnStart = arguments.contains(clearLeaseFlag)

            // A recognized flag passed more than once is a mistake → refuse, rather
            // than silently take the first and drop the rest.
            guard arguments.filter({ $0 == fingerprintFlag }).count <= 1 else {
                return .failure(.missingValue(flag: fingerprintFlag))
            }

            var fingerprintOverride: String?
            if let flagIndex = arguments.firstIndex(of: fingerprintFlag) {
                let valueIndex = arguments.index(after: flagIndex)
                // The value must be present and not another flag (a `--…` token is
                // not a value).
                guard valueIndex < arguments.endIndex,
                    !arguments[valueIndex].hasPrefix(flagPrefix)
                else {
                    return .failure(.missingValue(flag: fingerprintFlag))
                }
                let candidate = arguments[valueIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Never SHA-256("") — an empty/whitespace value would collide across
                // runs in the shared Keygen account.
                guard !candidate.isEmpty else {
                    return .failure(.missingValue(flag: fingerprintFlag))
                }
                fingerprintOverride = candidate
            }

            return .success(
                StowerLicenseDebugArguments(
                    clearLeaseOnStart: clearLeaseOnStart,
                    fingerprintOverride: fingerprintOverride
                )
            )
        }

        private static let clearLeaseFlag = "--clear-lease-on-start"
        private static let fingerprintFlag = "--fingerprint"
        private static let flagPrefix = "--"
    }

#endif
