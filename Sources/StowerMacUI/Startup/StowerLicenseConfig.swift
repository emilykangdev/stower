import Foundation

/// The app-side licensing endpoints + keys, resolved once at launch.
///
/// All three values are PUBLIC (the Edge Function URL, the Keygen account's
/// Ed25519 *public* key, the Lemon Squeezy checkout URL) — no secret ships in the
/// binary (the vendor-split invariant). So the compiled defaults are safe to ship.
///
/// Resolution layers, in order: the compiled default (`staging` in a `DEBUG`
/// build, `production` otherwise), then a per-field `STOWER_*` `ProcessInfo`
/// override when present. A normally-launched Release app sets none of those env
/// vars, so it uses the `production` defaults; a dev/test/CI run can point a build
/// at any deployment via the env vars without recompiling.
internal struct StowerLicenseConfig: Sendable, Equatable {
    /// The Supabase Edge Function base; `/mint-trial` and `/check-in` are appended.
    internal let functionBaseURL: String

    /// The Keygen account's Ed25519 public key (hex) for offline machine-file
    /// verification (I6).
    internal let keygenPublicKeyHex: String

    /// The Lemon Squeezy product checkout URL the Buy action opens.
    internal let checkoutBaseURL: String

    /// Production defaults — placeholders until a prod environment is stood up
    /// (G10): set the real prod Edge Function URL, Keygen public key, and LS
    /// product checkout URL here at prod ops.
    internal static let production = StowerLicenseConfig(
        functionBaseURL: "https://stower-license.supabase.co/functions/v1/license",
        keygenPublicKeyHex: placeholderKeygenPublicKeyHex,
        checkoutBaseURL: "https://stower.lemonsqueezy.com/checkout"
    )

    /// Staging defaults — the live test deployment a `DEBUG` build points at.
    internal static let staging = StowerLicenseConfig(
        functionBaseURL: "https://qxsrnsxvsgofaeblbmmv.supabase.co/functions/v1/license",
        keygenPublicKeyHex: "dbc3a1ff8e028cdee0e2156eddf123628e8ede2efc9332516c39e7488627c433",
        checkoutBaseURL: "https://stower.lemonsqueezy.com/checkout"
    )

    /// The compiled default for this build configuration.
    internal static let compiledDefault: StowerLicenseConfig = {
        #if DEBUG
            return staging
        #else
            return production
        #endif
    }()

    /// Applies the per-field `STOWER_*` environment overrides over `compiled`.
    ///
    /// Pure (the environment is injected) so the override/fallback logic is unit
    /// tested without mutating `ProcessInfo`. An unset or empty value falls back to
    /// the compiled field.
    internal static func resolve(
        environment: [String: String],
        compiled: StowerLicenseConfig
    ) -> StowerLicenseConfig {
        func override(_ key: String, _ fallback: String) -> String {
            guard let value = environment[key], !value.isEmpty else { return fallback }
            return value
        }
        return StowerLicenseConfig(
            functionBaseURL: override(functionURLEnvKey, compiled.functionBaseURL),
            keygenPublicKeyHex: override(keygenPublicKeyEnvKey, compiled.keygenPublicKeyHex),
            checkoutBaseURL: override(checkoutURLEnvKey, compiled.checkoutBaseURL)
        )
    }

    /// The config the app runs with: the compiled default with `STOWER_*` overrides
    /// applied from the launch environment.
    internal static let resolved = resolve(
        environment: ProcessInfo.processInfo.environment,
        compiled: compiledDefault
    )

    /// The all-zeros Keygen key placeholder — verifies nothing, the correct
    /// pre-prod-ops state for `production` (G10).
    private static let placeholderKeygenPublicKeyHex =
        "0000000000000000000000000000000000000000000000000000000000000000"

    /// `ProcessInfo` override keys (dev/test/CI point a build at any deployment).
    private static let functionURLEnvKey = "STOWER_FUNCTION_URL"
    private static let keygenPublicKeyEnvKey = "STOWER_KEYGEN_PUBLIC_KEY"
    private static let checkoutURLEnvKey = "STOWER_CHECKOUT_URL"
}
