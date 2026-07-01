import Foundation

/// The app-side backend endpoints + keys, resolved once at launch.
///
/// All values are PUBLIC (the Edge Function URLs, the Keygen account's
/// Ed25519 *public* key, the Lemon Squeezy checkout URL) — no secret ships in the
/// binary (the vendor-split invariant). So the compiled defaults are safe to ship.
///
/// Resolution layers, in order: the compiled default (`staging` in a `DEBUG`
/// build, `production` otherwise), then a per-field `STOWER_*` `ProcessInfo`
/// override applied **in DEBUG only**. A Release build pins the compiled
/// `production` config and ignores `STOWER_*` (`effectiveConfig` passes
/// `allowOverrides: false`), so a launch-environment variable cannot swap the
/// pinned Keygen trust anchor; a DEBUG dev/test/CI run can point a build at any
/// deployment via the env vars without recompiling.
internal struct StowerLicenseConfig: Sendable, Equatable {
    /// The Supabase Edge Function base; `/mint-trial` and `/check-in` are appended.
    internal let functionBaseURL: String

    /// The Keygen account's Ed25519 public key (hex) for offline machine-file
    /// verification (I6).
    internal let keygenPublicKeyHex: String

    /// The Lemon Squeezy product checkout URL the Buy action opens.
    internal let checkoutBaseURL: String

    /// The Supabase Edge Function base URL for feedback submissions (no trailing slash,
    /// no path segment — `StowerFeedbackClient` appends `/feedback`).
    ///
    /// Deployed `--no-verify-jwt` so the app sends no auth header, matching the
    /// license function's pattern (A1).
    internal let feedbackBaseURL: String

    /// Production defaults — the Keygen key is already real (same account as
    /// staging, account-level keypair); the Edge Function URL + LS checkout URL stay
    /// placeholders until a prod environment is stood up (G10).
    internal static let production = StowerLicenseConfig(
        functionBaseURL: "https://stower-license.supabase.co/functions/v1/license",
        keygenPublicKeyHex: accountPublicKeyHex,
        checkoutBaseURL: "https://stower.lemonsqueezy.com/checkout",
        feedbackBaseURL: "https://stower-license.supabase.co/functions/v1"
    )

    /// Staging defaults — the live test deployment a `DEBUG` build points at.
    internal static let staging = StowerLicenseConfig(
        functionBaseURL: "https://qxsrnsxvsgofaeblbmmv.supabase.co/functions/v1/license",
        keygenPublicKeyHex: accountPublicKeyHex,
        checkoutBaseURL:
            "https://emilykangdev.lemonsqueezy.com/checkout/buy/"
            + "4b930b6d-727b-4f93-9f9a-b4b8b738ab46",
        feedbackBaseURL: "https://qxsrnsxvsgofaeblbmmv.supabase.co/functions/v1"
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
            checkoutBaseURL: override(checkoutURLEnvKey, compiled.checkoutBaseURL),
            feedbackBaseURL: override(feedbackURLEnvKey, compiled.feedbackBaseURL)
        )
    }

    /// The effective config: the compiled default with `STOWER_*` overrides applied
    /// only when `allowOverrides` is true, else the compiled config verbatim.
    ///
    /// Pure (environment + flag injected) so both branches are unit tested. Release
    /// passes `allowOverrides: false` so a launch-environment variable cannot swap
    /// the pinned Keygen public key (the offline trust anchor) or endpoints and make
    /// the app accept forged machine files; overrides are a DEBUG dev/CI affordance.
    internal static func effectiveConfig(
        environment: [String: String],
        compiled: StowerLicenseConfig,
        allowOverrides: Bool
    ) -> StowerLicenseConfig {
        guard allowOverrides else { return compiled }
        return resolve(environment: environment, compiled: compiled)
    }

    /// The config the app runs with: compiled defaults, plus `STOWER_*` overrides in
    /// DEBUG only (Release pins the compiled config — see `effectiveConfig`).
    internal static let resolved: StowerLicenseConfig = {
        #if DEBUG
            let allowOverrides = true
        #else
            let allowOverrides = false
        #endif
        return effectiveConfig(
            environment: ProcessInfo.processInfo.environment,
            compiled: compiledDefault,
            allowOverrides: allowOverrides
        )
    }()

    /// The Stower Keygen account's Ed25519 public key (hex), used to verify signed
    /// machine files offline (I6).
    ///
    /// Account-level, so staging and production (same account) share it — replace
    /// only if production ever moves to its own account.
    private static let accountPublicKeyHex =
        "dbc3a1ff8e028cdee0e2156eddf123628e8ede2efc9332516c39e7488627c433"

    /// `ProcessInfo` override keys (dev/test/CI point a build at any deployment).
    private static let functionURLEnvKey = "STOWER_FUNCTION_URL"
    private static let keygenPublicKeyEnvKey = "STOWER_KEYGEN_PUBLIC_KEY"
    private static let checkoutURLEnvKey = "STOWER_CHECKOUT_URL"
    private static let feedbackURLEnvKey = "STOWER_FEEDBACK_BASE_URL"
}
