import Foundation

/// The app-side Lemon Squeezy identity, resolved once at launch.
///
/// All fields are PUBLIC (a store id, a product id, a checkout URL — no
/// secret ships in the binary). `/v1/licenses/activate` itself needs no API
/// key, so nothing here is a trust anchor to protect; `storeID`/`productID`
/// are load-bearing only in that a placeholder `0` fails every activation
/// closed (see `StowerLemonSqueezyClient`), not because they are secret.
///
/// Resolution layers, in order: the compiled default (`staging` in a `DEBUG`
/// build, `production` otherwise), then a per-field `STOWER_*` `ProcessInfo`
/// override applied **in DEBUG only**. A Release build pins the compiled
/// `production` config and ignores `STOWER_*` (`effectiveConfig` passes
/// `allowOverrides: false`), so a launch-environment variable cannot swap the
/// configured store/product identity; a DEBUG dev/test/CI run can point a
/// build at any store/product via the env vars without recompiling.
internal struct StowerLicenseConfig: Sendable, Equatable {
    /// The Lemon Squeezy checkout URL the Buy action opens.
    internal let checkoutURL: String

    /// Stower's Lemon Squeezy `store_id`; an `/activate` response must match
    /// this before the key is accepted (I1).
    internal let storeID: Int

    /// Stower's Lemon Squeezy `product_id`; an `/activate` response must
    /// match this before the key is accepted (I1).
    internal let productID: Int

    /// Production defaults — the live `store_id` is confirmed (supplied
    /// 2026-07-01, via `GET /v1/stores` with a live-mode API key); the
    /// product id and checkout URL stay fail-closed placeholders until
    /// Emily confirms the LIVE (not test-mode) product id (OQ1/OQ3) — a
    /// dashboard id read while Test mode was on can be the test object's id,
    /// which differs from its live counterpart.
    ///
    /// A placeholder `0` fails every activation closed; this is a release
    /// gate, not a bug (Known gotcha #2).
    internal static let production = StowerLicenseConfig(
        checkoutURL: "",
        storeID: 349_917,
        productID: 0
    )

    /// Staging defaults — the test-mode checkout link is real (supplied
    /// 2026-07-01); the ids stay fail-closed placeholders until the test-mode
    /// `/activate` spike reads them from `meta` (OQ2/OQ4).
    internal static let staging = StowerLicenseConfig(
        checkoutURL: "https://emilykangdev.lemonsqueezy.com"
            + "/checkout/buy/6cb4069d-ad6c-4d0a-a305-eb9632d35158",
        storeID: 0,
        productID: 0
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
    /// the compiled field. `storeID`/`productID` overrides that fail to parse as
    /// `Int` fall back to the compiled value rather than crash.
    internal static func resolve(
        environment: [String: String],
        compiled: StowerLicenseConfig
    ) -> StowerLicenseConfig {
        func stringOverride(_ key: String, _ fallback: String) -> String {
            guard let value = environment[key], !value.isEmpty else { return fallback }
            return value
        }
        func intOverride(_ key: String, _ fallback: Int) -> Int {
            guard let value = environment[key], let parsed = Int(value) else { return fallback }
            return parsed
        }
        return StowerLicenseConfig(
            checkoutURL: stringOverride(checkoutURLEnvKey, compiled.checkoutURL),
            storeID: intOverride(storeIDEnvKey, compiled.storeID),
            productID: intOverride(productIDEnvKey, compiled.productID)
        )
    }

    /// The effective config: the compiled default with `STOWER_*` overrides applied
    /// only when `allowOverrides` is true, else the compiled config verbatim.
    ///
    /// Pure (environment + flag injected) so both branches are unit tested. Release
    /// passes `allowOverrides: false` so a launch-environment variable cannot swap
    /// the configured store/product identity; overrides are a DEBUG dev/CI
    /// affordance.
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

    /// `ProcessInfo` override keys (dev/test/CI point a build at any store/product).
    private static let checkoutURLEnvKey = "STOWER_CHECKOUT_URL"
    private static let storeIDEnvKey = "STOWER_STORE_ID"
    private static let productIDEnvKey = "STOWER_PRODUCT_ID"
}
