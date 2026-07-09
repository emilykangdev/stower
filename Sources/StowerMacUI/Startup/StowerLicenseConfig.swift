import Foundation
import StowerCore

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

    /// Production defaults — all real (supplied 2026-07-01).
    ///
    /// `store_id` via `GET /v1/stores` with a live-mode API key;
    /// `product_id` confirmed live, not test-mode; the checkout URL is the
    /// live buy link (OQ1/OQ3 resolved). OQ3 was initially resolved with a
    /// checkout link that turned out to be the test-mode one (mislabeled at
    /// the source) — corrected once Emily supplied both links side by side.
    internal static let production = StowerLicenseConfig(
        checkoutURL: "https://emilykangdev.lemonsqueezy.com"
            + "/checkout/buy/6cb4069d-ad6c-4d0a-a305-eb9632d35158",
        storeID: 349_917,
        productID: 1_150_776
    )

    /// Staging defaults — all real, supplied 2026-07-01.
    ///
    /// Corrected after the two checkout links were confirmed side by side
    /// against production's.
    ///
    /// `store_id` is shared with `production`: Lemon Squeezy's "test mode" is
    /// a toggle on one store, not a separate store — only products/discounts
    /// get distinct ids via "Copy to Live Mode" (LS docs, confirmed via
    /// context7). `product_id` is this product's test-mode id, distinct from
    /// its live counterpart (`production.productID`).
    internal static let staging = StowerLicenseConfig(
        checkoutURL: "https://emilykangdev.lemonsqueezy.com"
            + "/checkout/buy/f12eccd6-d0be-4c99-bf61-3e76140c1ae5",
        storeID: 349_917,
        productID: 1_189_590
    )

    /// The compiled default for a given build variant (PAR-62 — replaces this
    /// type's own independent `#if DEBUG` detection with `StowerEnvironment`,
    /// the app's single source of truth for Debug/Release).
    internal static func compiledDefault(
        for environment: StowerEnvironment
    ) -> StowerLicenseConfig {
        switch environment {
        case .debug: return staging
        case .release: return production
        }
    }

    /// The compiled default for the build this binary was actually compiled as.
    internal static let compiledDefault: StowerLicenseConfig = compiledDefault(for: .current)

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
